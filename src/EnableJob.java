import java.io.BufferedReader;
import java.io.FileWriter;
import java.io.InputStreamReader;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Properties;
import java.util.UUID;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Background enable job with shared interactive TOTP.
 */
public class EnableJob implements Runnable {
    public static final int AUTH_FAIL_EXIT = 5;
    private static final String LOG_DIR = "/tmp/microz_logs";
    private static final String SCRIPT =
        "/Users/aswin-20182/Documents/Consumer pointing tool/MicrozToolProperties/enableLocalIDCConsumer.sh";

    public enum Status {
        RUNNING,
        AWAITING_TOTP,
        DONE,
        FAILED
    }

    private final String jobId;
    private final String appServerName;
    private final String[] consumerNames;
    private final TotpSession totpSession = new TotpSession();
    private final AtomicBoolean abort = new AtomicBoolean(false);
    private final long createdAt = System.currentTimeMillis();

    private volatile Status status = Status.RUNNING;
    private volatile String message = "";
    private volatile String resultsJson = "";
    private volatile ExecutorService pool;

    public EnableJob(String appServerName, String[] consumerNames) {
        this.jobId = UUID.randomUUID().toString();
        this.appServerName = appServerName != null ? appServerName : "";
        this.consumerNames = consumerNames != null ? consumerNames : new String[0];
    }

    public String getJobId() { return jobId; }
    public Status getStatus() {
        if (totpSession.needsTotp() && status == Status.RUNNING) {
            return Status.AWAITING_TOTP;
        }
        return status;
    }
    public String getMessage() {
        if (totpSession.needsTotp()) {
            return totpSession.getReason();
        }
        return message;
    }
    public String getResultsJson() { return resultsJson; }
    public TotpSession getTotpSession() { return totpSession; }
    public long getCreatedAt() { return createdAt; }
    public String getAppServerName() { return appServerName; }

    public boolean needsTotp() {
        return totpSession.needsTotp();
    }

    public String submitTotp(String code) {
        return totpSession.submitTotp(code);
    }

    public void cancel(String reason) {
        abort.set(true);
        totpSession.cancel(reason != null ? reason : "Cancelled by user");
        ExecutorService p = pool;
        if (p != null) {
            p.shutdownNow();
        }
        status = Status.FAILED;
        message = reason != null ? reason : "Cancelled";
        if (resultsJson == null || resultsJson.isEmpty()) {
            resultsJson = buildFailureResults(message);
        }
    }

    @Override
    public void run() {
        writeLog("===== NEW ENABLE JOB " + jobId + " =====");
        writeLog("AppServerName: " + appServerName);
        writeLog("ConsumerNames count: " + consumerNames.length);

        Properties appServerProp = MicrozChangeUtil.getAppServerProperties();
        Properties consumerProp = MicrozChangeUtil.getDeskConsumerProperties();

        StringBuilder json = new StringBuilder();
        json.append("{\"appServer\":\"").append(escapeJson(appServerName)).append("\",\"results\":[");

        try {
            if (consumerNames.length == 0 || appServerProp == null || consumerProp == null) {
                failJob("Missing consumers or properties");
                json.append("{\"consumer\":\"\",\"success\":false,\"message\":\"")
                    .append(escapeJson(message)).append("\"}]}");
                resultsJson = json.toString();
                return;
            }

            for (int i = 0; i < consumerNames.length; i++) {
                if (abort.get() || totpSession.isCancelledOrTimedOut()) {
                    failJob(totpSession.getCancelMessage().isEmpty()
                        ? "Job aborted" : totpSession.getCancelMessage());
                    break;
                }

                String consumerName = consumerNames[i];
                String consumerPropValue = consumerProp.getProperty(consumerName);
                int hostsTried = 0;
                int hostsSucceeded = 0;
                int targetHostsTried = 0;
                int targetHostsSucceeded = 0;
                String firstError = "";

                writeLog("---- Consumer start: " + consumerName + " ----");

                if (consumerPropValue == null || consumerPropValue.isEmpty()) {
                    firstError = "Consumer entry missing in properties";
                } else {
                    String[] consumerCommentValue = consumerPropValue.split(",", 2);
                    final String startMarker = consumerCommentValue.length > 0 ? consumerCommentValue[0] : "";
                    final String endMarker = consumerCommentValue.length > 1 ? consumerCommentValue[1] : "";

                    List<Callable<int[]>> tasks = new ArrayList<>();
                    final List<String[]> taskMeta = new ArrayList<>();

                    for (Object eachAppKey : appServerProp.keySet()) {
                        final boolean isTarget = appServerName.equals(eachAppKey.toString());
                        final String consumerEnable = isTarget ? "true" : "false";
                        String appServerIp = appServerProp.getProperty(eachAppKey.toString());
                        if (appServerIp == null || appServerIp.isEmpty()) continue;

                        for (String eachServerIp : appServerIp.split(",")) {
                            final String hostIp = eachServerIp.trim();
                            if (hostIp.isEmpty()) continue;
                            taskMeta.add(new String[]{hostIp, consumerEnable, isTarget ? "1" : "0"});
                            tasks.add(new Callable<int[]>() {
                                public int[] call() {
                                    return runHostWithTotp(hostIp, startMarker, endMarker, consumerEnable, isTarget);
                                }
                            });
                        }
                    }

                    pool = Executors.newFixedThreadPool(Math.min(Math.max(tasks.size(), 1), 20));
                    try {
                        List<Future<int[]>> futures = pool.invokeAll(tasks);
                        for (int t = 0; t < futures.size(); t++) {
                            try {
                                int[] result = futures.get(t).get();
                                int exitCode = result[0];
                                boolean isTarget = result[1] == 1;
                                boolean fatal = result.length > 2 && result[2] == 1;
                                String hostIp = taskMeta.get(t)[0];
                                hostsTried++;
                                if (isTarget) targetHostsTried++;
                                if (exitCode == 0) {
                                    hostsSucceeded++;
                                    if (isTarget) targetHostsSucceeded++;
                                } else if (firstError.isEmpty()) {
                                    firstError = "Host " + hostIp + " failed with exit " + exitCode;
                                }
                                if (fatal) {
                                    abort.set(true);
                                    failJob(totpSession.getCancelMessage().isEmpty()
                                        ? "TOTP authentication failed; job aborted"
                                        : totpSession.getCancelMessage());
                                }
                            } catch (Exception e) {
                                writeLog("Task result error: " + e.getMessage());
                                if (firstError.isEmpty()) {
                                    firstError = e.getMessage() != null ? e.getMessage() : "task error";
                                }
                            }
                        }
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                        failJob("Parallel execution interrupted");
                    } finally {
                        pool.shutdown();
                        try {
                            pool.awaitTermination(5, TimeUnit.SECONDS);
                        } catch (InterruptedException e) {
                            Thread.currentThread().interrupt();
                        }
                        pool = null;
                    }
                }

                boolean success = !abort.get()
                    && targetHostsTried > 0
                    && targetHostsSucceeded == targetHostsTried;
                String consumerMessage = "Enabled on " + targetHostsSucceeded + "/" + targetHostsTried
                    + " target hosts (" + hostsSucceeded + "/" + hostsTried + " total)";
                if (!firstError.isEmpty()) {
                    consumerMessage = consumerMessage + ". " + firstError;
                }
                if (abort.get() && !totpSession.getCancelMessage().isEmpty()) {
                    consumerMessage = totpSession.getCancelMessage();
                    success = false;
                }

                if (i > 0) {
                    json.append(",");
                }
                json.append("{\"consumer\":\"").append(escapeJson(consumerName)).append("\",")
                    .append("\"success\":").append(success).append(",")
                    .append("\"message\":\"").append(escapeJson(consumerMessage)).append("\"}");
                writeLog("---- Consumer end: " + consumerName + " => " + consumerMessage + " ----");

                if (abort.get()) {
                    break;
                }
            }

            json.append("]}");
            resultsJson = json.toString();
            if (status != Status.FAILED) {
                status = Status.DONE;
                message = "Completed";
            }
            writeLog("Job " + jobId + " finished with status=" + status);
        } catch (Exception e) {
            failJob("Unexpected error: " + e.getMessage());
            resultsJson = buildFailureResults(message);
            writeLog("Job " + jobId + " error: " + e.getMessage());
        }
    }

    /**
     * @return int[]{exitCode, isTarget(0/1), fatal(0/1)}
     */
    private int[] runHostWithTotp(String hostIp, String startMarker, String endMarker,
                                  String consumerEnable, boolean isTarget) {
        int targetFlag = isTarget ? 1 : 0;
        try {
            if (abort.get() || totpSession.isCancelledOrTimedOut()) {
                return new int[]{-1, targetFlag, 1};
            }

            String totp = totpSession.ensureTotp("Enter TOTP to authenticate SSH.");
            if (totp == null) {
                abort.set(true);
                if (!totpSession.isCancelledOrTimedOut()) {
                    totpSession.cancel("TOTP not entered within 60 seconds. Job aborted.");
                }
                ExecutorService p = pool;
                if (p != null) {
                    p.shutdownNow();
                }
                return new int[]{-1, targetFlag, 1};
            }

            int exitCode = runSsh(hostIp, startMarker, endMarker, consumerEnable, totp);
            if (exitCode == AUTH_FAIL_EXIT) {
                writeLog("Auth failure on " + hostIp + "; re-asking TOTP");
                totpSession.invalidateCode();
                String newTotp = totpSession.reaskTotp(
                    "Invalid or expired TOTP. Enter a new code within 60 seconds.");
                if (newTotp == null) {
                    abort.set(true);
                    if (!totpSession.isCancelledOrTimedOut()) {
                        totpSession.cancel("TOTP not re-entered within 60 seconds. Job aborted.");
                    }
                    ExecutorService p = pool;
                    if (p != null) {
                        p.shutdownNow();
                    }
                    return new int[]{AUTH_FAIL_EXIT, targetFlag, 1};
                }
                exitCode = runSsh(hostIp, startMarker, endMarker, consumerEnable, newTotp);
                if (exitCode == AUTH_FAIL_EXIT) {
                    abort.set(true);
                    totpSession.cancel("TOTP authentication failed after retry. Job aborted.");
                    ExecutorService p = pool;
                    if (p != null) {
                        p.shutdownNow();
                    }
                    return new int[]{AUTH_FAIL_EXIT, targetFlag, 1};
                }
            }
            return new int[]{exitCode, targetFlag, 0};
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return new int[]{-1, targetFlag, abort.get() ? 1 : 0};
        } catch (Exception e) {
            writeLog("ERROR on " + hostIp + ": " + e.getMessage());
            return new int[]{-1, targetFlag, 0};
        }
    }

    private int runSsh(String hostIp, String startMarker, String endMarker,
                       String consumerEnable, String totp) throws Exception {
        ArrayList<String> cmdList = new ArrayList<>();
        cmdList.add("sh");
        cmdList.add(SCRIPT);
        cmdList.add("sas@" + hostIp);
        cmdList.add(startMarker);
        cmdList.add(endMarker);
        cmdList.add(consumerEnable);

        writeLog("Executing command on host: " + hostIp + ", enable=" + consumerEnable);
        ProcessBuilder pb = new ProcessBuilder(cmdList);
        pb.environment().put("MICROZ_SSH_TOTP", totp);
        pb.redirectErrorStream(true);
        Process process = pb.start();
        BufferedReader reader = new BufferedReader(new InputStreamReader(process.getInputStream()));
        String line;
        while ((line = reader.readLine()) != null) {
            writeLog("OUTPUT [" + hostIp + "]: " + line);
        }
        int exitCode = process.waitFor();
        writeLog("Exit code for " + hostIp + ": " + exitCode);
        return exitCode;
    }

    private void failJob(String msg) {
        status = Status.FAILED;
        message = msg != null ? msg : "Failed";
        abort.set(true);
    }

    private String buildFailureResults(String msg) {
        return "{\"appServer\":\"" + escapeJson(appServerName)
            + "\",\"results\":[{\"consumer\":\"\",\"success\":false,\"message\":\""
            + escapeJson(msg) + "\"}]}";
    }

    private static String escapeJson(String value) {
        if (value == null) {
            return "";
        }
        return value.replace("\\", "\\\\")
            .replace("\"", "\\\"")
            .replace("\n", "\\n")
            .replace("\r", "\\r");
    }

    private static void writeLog(String message) {
        try {
            String timestamp = new SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS").format(new Date());
            String logFile = LOG_DIR + "/microz_execution.log";
            FileWriter fw = new FileWriter(logFile, true);
            fw.write("[" + timestamp + "] " + message + "\n");
            fw.close();
        } catch (Exception e) {
            e.printStackTrace();
        }
    }
}
