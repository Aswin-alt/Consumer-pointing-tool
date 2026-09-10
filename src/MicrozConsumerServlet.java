import java.io.IOException;
import java.util.Iterator;
import java.util.Map;
import java.util.Properties;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileWriter;
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
    private static final long JOB_TTL_MS = 30L * 60L * 1000L;

    private static final ConcurrentHashMap<String, EnableJob> JOBS = new ConcurrentHashMap<>();
    private static final ExecutorService JOB_EXECUTOR = Executors.newCachedThreadPool();

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

    private void cleanupOldJobs() {
        long now = System.currentTimeMillis();
        Iterator<Map.Entry<String, EnableJob>> it = JOBS.entrySet().iterator();
        while (it.hasNext()) {
            Map.Entry<String, EnableJob> e = it.next();
            EnableJob job = e.getValue();
            EnableJob.Status st = job.getStatus();
            boolean terminal = st == EnableJob.Status.DONE || st == EnableJob.Status.FAILED;
            if (terminal && (now - job.getCreatedAt()) > JOB_TTL_MS) {
                it.remove();
            }
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

            // ─── Async enable job APIs ─────────────────────────────────
            if ("startEnable".equals(action)) {
                cleanupOldJobs();
                String appServerName = request.getParameter("AppServerName") != null
                        ? request.getParameter("AppServerName").toString() : "";
                String[] consumerNames = request.getParameterValues("ConsumerName");
                if (consumerNames == null || consumerNames.length == 0) {
                    String oneConsumer = request.getParameter("ConsumerName") != null
                            ? request.getParameter("ConsumerName").toString() : "";
                    if (!oneConsumer.isEmpty()) {
                        consumerNames = new String[] { oneConsumer };
                    }
                }

                response.setContentType("application/json; charset=UTF-8");
                if (appServerName.isEmpty()) {
                    response.getWriter().write("{\"success\":false,\"message\":\"App server is required\"}");
                    return;
                }
                if (consumerNames == null || consumerNames.length == 0) {
                    response.getWriter().write("{\"success\":false,\"message\":\"At least one consumer is required\"}");
                    return;
                }

                EnableJob job = new EnableJob(appServerName, consumerNames);
                JOBS.put(job.getJobId(), job);
                JOB_EXECUTOR.execute(job);
                writeLog("Started enable job " + job.getJobId());
                response.getWriter().write("{\"success\":true,\"jobId\":\"" + escapeJson(job.getJobId()) + "\"}");
                return;
            }

            if ("jobStatus".equals(action)) {
                cleanupOldJobs();
                String jobId = request.getParameter("jobId") != null
                        ? request.getParameter("jobId").trim() : "";
                response.setContentType("application/json; charset=UTF-8");
                EnableJob job = JOBS.get(jobId);
                if (job == null) {
                    response.getWriter().write("{\"success\":false,\"message\":\"Unknown jobId\"}");
                    return;
                }

                EnableJob.Status st = job.getStatus();
                String statusName = st.name().toLowerCase();
                boolean needsTotp = job.needsTotp();
                TotpSession session = job.getTotpSession();

                StringBuilder sb = new StringBuilder();
                sb.append("{\"success\":true")
                  .append(",\"jobId\":\"").append(escapeJson(jobId)).append("\"")
                  .append(",\"status\":\"").append(statusName).append("\"")
                  .append(",\"message\":\"").append(escapeJson(job.getMessage())).append("\"")
                  .append(",\"needsTotp\":").append(needsTotp)
                  .append(",\"totpReason\":\"").append(escapeJson(session.getReason())).append("\"")
                  .append(",\"totpReAsk\":").append(session.isReAsk())
                  .append(",\"totpSecondsRemaining\":").append(session.getSecondsRemaining());

                if (st == EnableJob.Status.DONE || st == EnableJob.Status.FAILED) {
                    String results = job.getResultsJson();
                    if (results != null && !results.isEmpty()) {
                        // Full enable result object: {appServer, results:[...]}
                        sb.append(",\"payload\":").append(results);
                    }
                }
                sb.append("}");
                response.getWriter().write(sb.toString());
                return;
            }

            if ("submitTotp".equals(action)) {
                String jobId = request.getParameter("jobId") != null
                        ? request.getParameter("jobId").trim() : "";
                String totp = request.getParameter("totp") != null
                        ? request.getParameter("totp").trim() : "";
                response.setContentType("application/json; charset=UTF-8");
                EnableJob job = JOBS.get(jobId);
                if (job == null) {
                    response.getWriter().write("{\"success\":false,\"message\":\"Unknown jobId\"}");
                    return;
                }
                String err = job.submitTotp(totp);
                if (err != null) {
                    response.getWriter().write("{\"success\":false,\"message\":\"" + escapeJson(err) + "\"}");
                } else {
                    writeLog("TOTP submitted for job " + jobId);
                    response.getWriter().write("{\"success\":true}");
                }
                return;
            }

            if ("cancelJob".equals(action)) {
                String jobId = request.getParameter("jobId") != null
                        ? request.getParameter("jobId").trim() : "";
                response.setContentType("application/json; charset=UTF-8");
                EnableJob job = JOBS.get(jobId);
                if (job == null) {
                    response.getWriter().write("{\"success\":false,\"message\":\"Unknown jobId\"}");
                    return;
                }
                job.cancel("Cancelled by user");
                writeLog("Job " + jobId + " cancelled by user");
                response.getWriter().write("{\"success\":true}");
                return;
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
