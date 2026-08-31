import java.io.IOException;
import java.util.ArrayList;
import java.util.List;
import java.util.Properties;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileWriter;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.text.SimpleDateFormat;
import java.util.Date;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.servlet.http.HttpSession;

public class MicrozConsumerServlet extends HttpServlet {
    private static final long serialVersionUID = 1L;
    private static final String LOG_DIR = "/tmp/microz_logs";
    private static final String ADMIN_CONFIG_FILE =
        "/Users/aswin-20182/Documents/Consumer pointing tool/MicrozToolProperties/admin.properties";

    private static String getAdminProperty(String key, String fallback) {
        try {
            Properties p = new Properties();
            p.load(new FileInputStream(ADMIN_CONFIG_FILE));
            String val = p.getProperty(key);
            return (val != null && !val.isEmpty()) ? val : fallback;
        } catch (Exception e) {
            return fallback;
        }
    }

    static {
        File logDir = new File(LOG_DIR);
        if (!logDir.exists()) {
            logDir.mkdirs();
        }
    }

    private void writeLog(String message) {
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

    protected void doGet(HttpServletRequest request, HttpServletResponse response)
            throws ServletException, IOException {
        try {
            String action = request.getParameter("action") != null
                    ? request.getParameter("action").toString() : "";

            if ("loadAppServerIp".equals(action)) {
                String loadData = MicrozChangeUtil.loadMicrozFormData();
                response.setContentType("text/html");
                response.getWriter().println(loadData);
                return;
            }

            if ("enableConsumer".equals(action)) {
                String appServerName = request.getParameter("AppServerName") != null
                        ? request.getParameter("AppServerName").toString() : "";
                String totp = request.getParameter("totp") != null
                        ? request.getParameter("totp").trim() : "";
                String[] consumerNames = request.getParameterValues("ConsumerName");
                if (consumerNames == null || consumerNames.length == 0) {
                    String oneConsumer = request.getParameter("ConsumerName") != null
                            ? request.getParameter("ConsumerName").toString() : "";
                    if (!oneConsumer.isEmpty()) {
                        consumerNames = new String[] { oneConsumer };
                    }
                }

                response.setContentType("application/json; charset=UTF-8");
                if (totp.isEmpty() || !totp.matches("\\d{6,8}")) {
                    writeLog("Enable request rejected: missing or invalid TOTP");
                    response.getWriter().write("{\"appServer\":\"" + escapeJson(appServerName)
                            + "\",\"results\":[{\"consumer\":\"\",\"success\":false,"
                            + "\"message\":\"TOTP is required (6-8 digits). Enter your current authenticator code.\"}]}");
                    return;
                }

                final String totpCode = totp;

                writeLog("===== NEW ENABLE REQUEST =====");
                writeLog("AppServerName: " + appServerName);
                writeLog("ConsumerNames count: " + (consumerNames == null ? 0 : consumerNames.length));

                Properties appServerProp = MicrozChangeUtil.getAppServerProperties();
                Properties consumerProp = MicrozChangeUtil.getDeskConsumerProperties();

                StringBuilder json = new StringBuilder();
                json.append("{\"appServer\":\"").append(escapeJson(appServerName)).append("\",\"results\":[");

                if (consumerNames != null && consumerNames.length > 0 && appServerProp != null && consumerProp != null) {
                    for (int i = 0; i < consumerNames.length; i++) {
                        String consumerName = consumerNames[i];
                        String consumerPropValue = consumerProp.getProperty(consumerName);
                        int hostsTried = 0;
                        int hostsSucceeded = 0;
                        int targetHostsTried = 0;
                        int targetHostsSucceeded = 0;
                        String firstError = "";

                        writeLog("---- Consumer start: " + consumerName + " ----");
                        writeLog("Consumer property value: " + consumerPropValue);

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
                                            ArrayList<String> cmdList = new ArrayList<>();
                                            cmdList.add("sh");
                                            cmdList.add("/Users/aswin-20182/Documents/Consumer pointing tool/MicrozToolProperties/enableLocalIDCConsumer.sh");
                                            cmdList.add("sas@" + hostIp);
                                            cmdList.add(startMarker);
                                            cmdList.add(endMarker);
                                            cmdList.add(consumerEnable);

                                            writeLog("Executing command on host: " + hostIp + ", enable=" + consumerEnable);
                                            writeLog("Command: " + String.join(" ", cmdList));
                                            try {
                                                ProcessBuilder pb = new ProcessBuilder(cmdList);
                                                pb.environment().put("MICROZ_SSH_TOTP", totpCode);
                                                pb.redirectErrorStream(true);
                                                Process process = pb.start();
                                                BufferedReader reader = new BufferedReader(new InputStreamReader(process.getInputStream()));
                                                String line;
                                                while ((line = reader.readLine()) != null) {
                                                    writeLog("OUTPUT [" + hostIp + "]: " + line);
                                                }
                                                int exitCode = process.waitFor();
                                                writeLog("Exit code for " + hostIp + ": " + exitCode);
                                                return new int[]{exitCode, isTarget ? 1 : 0};
                                            } catch (Exception e) {
                                                writeLog("ERROR on " + hostIp + ": " + e.getMessage());
                                                return new int[]{-1, isTarget ? 1 : 0};
                                            }
                                        }
                                    });
                                }
                            }

                            ExecutorService pool = Executors.newFixedThreadPool(Math.min(tasks.size(), 20));
                            try {
                                List<Future<int[]>> futures = pool.invokeAll(tasks);
                                for (int t = 0; t < futures.size(); t++) {
                                    try {
                                        int[] result = futures.get(t).get();
                                        int exitCode = result[0];
                                        boolean isTarget = result[1] == 1;
                                        String hostIp = taskMeta.get(t)[0];
                                        hostsTried++;
                                        if (isTarget) targetHostsTried++;
                                        if (exitCode == 0) {
                                            hostsSucceeded++;
                                            if (isTarget) targetHostsSucceeded++;
                                        } else if (firstError.isEmpty()) {
                                            firstError = "Host " + hostIp + " failed with exit " + exitCode;
                                        }
                                    } catch (Exception e) {
                                        writeLog("Task result error: " + e.getMessage());
                                    }
                                }
                            } catch (InterruptedException e) {
                                Thread.currentThread().interrupt();
                                writeLog("Parallel execution interrupted: " + e.getMessage());
                            } finally {
                                pool.shutdown();
                            }
                        }

                        boolean success = targetHostsTried > 0 && targetHostsSucceeded == targetHostsTried;
                        String message = "Enabled on " + targetHostsSucceeded + "/" + targetHostsTried
                                + " target hosts (" + hostsSucceeded + "/" + hostsTried + " total)";
                        if (!firstError.isEmpty()) {
                            message = message + ". " + firstError;
                        }

                        if (i > 0) {
                            json.append(",");
                        }
                        json.append("{\"consumer\":\"").append(escapeJson(consumerName)).append("\",")
                                .append("\"success\":").append(success).append(",")
                                .append("\"message\":\"").append(escapeJson(message)).append("\"}");
                        writeLog("---- Consumer end: " + consumerName + " => " + message + " ----");
                    }
                }

                json.append("]}");
                writeLog("Response sent to client");
                response.setContentType("application/json; charset=UTF-8");
                response.getWriter().write(json.toString());
            }

            // ─── Admin: Login ───────────────────────────────────────────
            if ("adminLogin".equals(action)) {
                String username = request.getParameter("username") != null ? request.getParameter("username") : "";
                String password = request.getParameter("password") != null ? request.getParameter("password") : "";
                response.setContentType("application/json; charset=UTF-8");
                String adminUser = getAdminProperty("admin.username", "user");
                String adminPass = getAdminProperty("admin.password", "");
                if (adminUser.equals(username) && adminPass.equals(password)) {
                    HttpSession session = request.getSession(true);
                    session.setAttribute("adminLoggedIn", Boolean.TRUE);
                    session.setMaxInactiveInterval(1800);
                    response.getWriter().write("{\"success\":true}");
                } else {
                    response.getWriter().write("{\"success\":false,\"message\":\"Invalid credentials\"}");
                }
                return;
            }

            if ("adminLogout".equals(action)) {
                HttpSession session = request.getSession(false);
                if (session != null) { session.invalidate(); }
                response.setContentType("application/json; charset=UTF-8");
                response.getWriter().write("{\"success\":true}");
                return;
            }

            if ("adminCheck".equals(action)) {
                HttpSession session = request.getSession(false);
                boolean loggedIn = session != null && Boolean.TRUE.equals(session.getAttribute("adminLoggedIn"));
                response.setContentType("application/json; charset=UTF-8");
                response.getWriter().write("{\"loggedIn\":" + loggedIn + "}");
                return;
            }

            // ─── Admin: Load data ───────────────────────────────────────
            if ("loadAdminData".equals(action)) {
                if (!isAdminSession(request)) {
                    response.setStatus(403);
                    response.setContentType("application/json; charset=UTF-8");
                    response.getWriter().write("{\"error\":\"Not authorized\"}");
                    return;
                }
                Properties appProps = MicrozChangeUtil.getAppServerProperties();
                Properties conProps = MicrozChangeUtil.getDeskConsumerProperties();
                StringBuilder sb = new StringBuilder("{\"appservers\":{");
                if (appProps != null) {
                    boolean first = true;
                    for (Object key : appProps.keySet()) {
                        if (!first) sb.append(",");
                        sb.append("\"").append(escapeJson(key.toString())).append("\":\"")
                          .append(escapeJson(appProps.getProperty(key.toString()))).append("\"");
                        first = false;
                    }
                }
                sb.append("},\"consumers\":{");
                if (conProps != null) {
                    boolean first = true;
                    for (Object key : conProps.keySet()) {
                        if (!first) sb.append(",");
                        sb.append("\"").append(escapeJson(key.toString())).append("\":\"")
                          .append(escapeJson(conProps.getProperty(key.toString()))).append("\"");
                        first = false;
                    }
                }
                sb.append("}}");
                response.setContentType("application/json; charset=UTF-8");
                response.getWriter().write(sb.toString());
                return;
            }

            // ─── Admin: Save entry ──────────────────────────────────────
            if ("saveAppServer".equals(action) || "saveConsumer".equals(action)) {
                if (!isAdminSession(request)) {
                    response.setStatus(403);
                    response.setContentType("application/json; charset=UTF-8");
                    response.getWriter().write("{\"error\":\"Not authorized\"}");
                    return;
                }
                String key = request.getParameter("key") != null ? request.getParameter("key").trim() : "";
                String value = request.getParameter("value") != null ? request.getParameter("value").trim() : "";
                response.setContentType("application/json; charset=UTF-8");
                if (key.isEmpty()) {
                    response.getWriter().write("{\"success\":false,\"message\":\"Key cannot be empty\"}");
                    return;
                }
                boolean ok;
                if ("saveAppServer".equals(action)) {
                    ok = MicrozChangeUtil.saveProperty("appserver", key, value);
                } else {
                    ok = MicrozChangeUtil.saveProperty("consumer", key, value);
                }
                response.getWriter().write("{\"success\":" + ok + "}");
                return;
            }

            // ─── Admin: Delete entry ────────────────────────────────────
            if ("deleteAppServer".equals(action) || "deleteConsumer".equals(action)) {
                if (!isAdminSession(request)) {
                    response.setStatus(403);
                    response.setContentType("application/json; charset=UTF-8");
                    response.getWriter().write("{\"error\":\"Not authorized\"}");
                    return;
                }
                String key = request.getParameter("key") != null ? request.getParameter("key").trim() : "";
                response.setContentType("application/json; charset=UTF-8");
                if (key.isEmpty()) {
                    response.getWriter().write("{\"success\":false,\"message\":\"Key cannot be empty\"}");
                    return;
                }
                boolean ok;
                if ("deleteAppServer".equals(action)) {
                    ok = MicrozChangeUtil.deleteProperty("appserver", key);
                } else {
                    ok = MicrozChangeUtil.deleteProperty("consumer", key);
                }
                response.getWriter().write("{\"success\":" + ok + "}");
                return;
            }
        } catch (IOException e) {
            e.printStackTrace();
        }
    }

    private String escapeJson(String value) {
        if (value == null) {
            return "";
        }
        return value.replace("\\", "\\\\")
                .replace("\"", "\\\"")
                .replace("\n", "\\n")
                .replace("\r", "\\r");
    }

    private boolean isAdminSession(HttpServletRequest request) {
        HttpSession session = request.getSession(false);
        return session != null && Boolean.TRUE.equals(session.getAttribute("adminLoggedIn"));
    }

    protected void doPost(HttpServletRequest request, HttpServletResponse response)
            throws ServletException, IOException {
        doGet(request, response);
    }
}
