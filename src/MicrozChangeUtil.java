import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.util.Properties;
import java.util.logging.Level;
import java.util.logging.Logger;

public class MicrozChangeUtil {
    private static final Logger LOGGER = Logger.getLogger(MicrozChangeUtil.class.getName());
    private static final String APPSERVER_FILE = "/Users/aswin-20182/Documents/Consumer pointing tool/MicrozToolProperties/appserver.properties";
    private static final String CONSUMER_FILE  = "/Users/aswin-20182/Documents/Consumer pointing tool/MicrozToolProperties/DeskConsumer.properties";

    public static String loadMicrozFormData() {
        Properties prop = getAppServerProperties();
        Properties consumerprop = getDeskConsumerProperties();

        String html = "<div class=\"formInput\">"
            + "<label class=\"formLabel\" for=\"AppServerName\">App Server</label>"
            + "<select id=\"AppServerName\" name=\"AppServerName\">"
            + "<option value=\"\">Select app server</option>";
        if (prop != null) {
            for (Object appServerName : prop.keySet()) {
                String safeName = escapeHtml(appServerName.toString());
                html += "<option value=\"" + safeName + "\">" + safeName + "</option>";
            }
        }
        html += "</select></div>";
        html += "<div class=\"formInput consumer-field\">"
            + "<label class=\"formLabel\" for=\"ConsumerName\">Consumers</label>"
            + "<select id=\"ConsumerName\" name=\"ConsumerName\" multiple=\"multiple\">";
        if (consumerprop != null) {
            for (Object consumerName : consumerprop.keySet()) {
                String safeName = escapeHtml(consumerName.toString());
                html += "<option value=\"" + safeName + "\">" + safeName + "</option>";
            }
        }
        html += "</select>"
            + "<div class=\"tip\">Tip: You can select multiple consumers.</div>"
            + "</div>";
        html += "<div class=\"formInput\"><button id=\"enableBtn\""
            + " class=\"button\" type=\"button\">Enable Consumers</button></div>";
        return html;
    }

    private static String escapeHtml(String value) {
        return value.replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace("\"", "&quot;")
            .replace("'", "&#39;");
    }

    public static Properties getAppServerProperties() {
        return getProperties(APPSERVER_FILE);
    }

    public static Properties getDeskConsumerProperties() {
        return getProperties(CONSUMER_FILE);
    }

    private static Properties getProperties(String propsFile) {
        try {
            Properties props = new Properties();
            props.load(new FileInputStream(propsFile));
            LOGGER.log(Level.INFO, "Loaded MicroZ Conf File :: " + propsFile);
            return props;
        } catch (Exception ex) {
            LOGGER.log(Level.SEVERE, "Unable to load Conf File for MicroZ :: " + propsFile, ex);
            return null;
        }
    }

    public static synchronized boolean saveProperty(String type, String key, String value) {
        try {
            String file = "appserver".equals(type) ? APPSERVER_FILE : CONSUMER_FILE;
            Properties props = new Properties();
            props.load(new FileInputStream(file));
            props.setProperty(key, value);
            FileOutputStream fos = new FileOutputStream(file);
            props.store(fos, null);
            fos.close();
            return true;
        } catch (Exception e) {
            LOGGER.log(Level.SEVERE, "Failed to save property: " + key, e);
            return false;
        }
    }

    public static synchronized boolean deleteProperty(String type, String key) {
        try {
            String file = "appserver".equals(type) ? APPSERVER_FILE : CONSUMER_FILE;
            Properties props = new Properties();
            props.load(new FileInputStream(file));
            if (props.remove(key) == null) return false;
            FileOutputStream fos = new FileOutputStream(file);
            props.store(fos, null);
            fos.close();
            return true;
        } catch (Exception e) {
            LOGGER.log(Level.SEVERE, "Failed to delete property: " + key, e);
            return false;
        }
    }
}
