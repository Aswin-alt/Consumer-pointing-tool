import java.util.concurrent.TimeUnit;
import java.util.concurrent.locks.Condition;
import java.util.concurrent.locks.ReentrantLock;

/**
 * Shared TOTP gate for one enable job.
 * Workers block until the UI submits a code, or until the deadline expires.
 * Only one prompt is active at a time; concurrent waiters share it.
 */
public class TotpSession {
    public static final long DEFAULT_TIMEOUT_MS = 60_000L;

    public enum Phase {
        IDLE,
        AWAITING_TOTP,
        HAS_CODE,
        CANCELLED,
        TIMED_OUT
    }

    private final ReentrantLock lock = new ReentrantLock();
    private final Condition codeReady = lock.newCondition();

    private Phase phase = Phase.IDLE;
    private String currentCode = null;
    private String reason = "";
    private long deadlineMs = 0L;
    private boolean reAsk = false;
    private String cancelMessage = "";
    private int generation = 0;

    public boolean isAwaitingTotp() {
        lock.lock();
        try {
            return phase == Phase.AWAITING_TOTP;
        } finally {
            lock.unlock();
        }
    }

    public boolean needsTotp() {
        return isAwaitingTotp();
    }

    public String getReason() {
        lock.lock();
        try {
            return reason;
        } finally {
            lock.unlock();
        }
    }

    public boolean isReAsk() {
        lock.lock();
        try {
            return reAsk;
        } finally {
            lock.unlock();
        }
    }

    public long getSecondsRemaining() {
        lock.lock();
        try {
            if (phase != Phase.AWAITING_TOTP || deadlineMs <= 0) {
                return 0;
            }
            long rem = deadlineMs - System.currentTimeMillis();
            return rem <= 0 ? 0 : (rem + 999) / 1000;
        } finally {
            lock.unlock();
        }
    }

    public String getCancelMessage() {
        lock.lock();
        try {
            return cancelMessage;
        } finally {
            lock.unlock();
        }
    }

    public boolean isCancelledOrTimedOut() {
        lock.lock();
        try {
            return phase == Phase.CANCELLED || phase == Phase.TIMED_OUT;
        } finally {
            lock.unlock();
        }
    }

    /**
     * Ensure a usable TOTP exists. Prompts the UI if none is available.
     * @return the TOTP code, or null if timed out / cancelled
     */
    public String ensureTotp(String promptReason) throws InterruptedException {
        lock.lock();
        try {
            if (phase == Phase.CANCELLED || phase == Phase.TIMED_OUT) {
                return null;
            }
            if (phase == Phase.HAS_CODE && currentCode != null && !currentCode.isEmpty()) {
                return currentCode;
            }
            if (phase != Phase.AWAITING_TOTP) {
                startPromptLocked(promptReason, false);
            }
            return waitForCodeLocked();
        } finally {
            lock.unlock();
        }
    }

    /**
     * Invalidate the current code and re-ask the UI (auth failure path).
     * Concurrent callers share a single re-ask prompt.
     * @return new TOTP, or null on timeout/cancel
     */
    public String reaskTotp(String promptReason) throws InterruptedException {
        lock.lock();
        try {
            if (phase == Phase.CANCELLED || phase == Phase.TIMED_OUT) {
                return null;
            }
            // Already prompting — join that wait (do not reset deadline)
            if (phase == Phase.AWAITING_TOTP) {
                return waitForCodeLocked();
            }
            currentCode = null;
            startPromptLocked(promptReason, true);
            return waitForCodeLocked();
        } finally {
            lock.unlock();
        }
    }

    public void invalidateCode() {
        lock.lock();
        try {
            currentCode = null;
            if (phase == Phase.HAS_CODE) {
                phase = Phase.IDLE;
            }
        } finally {
            lock.unlock();
        }
    }

    /**
     * Called by the UI when the user submits a TOTP.
     * @return null on success, or an error message
     */
    public String submitTotp(String code) {
        if (code == null) {
            code = "";
        }
        code = code.trim();
        if (!code.matches("\\d{6,8}")) {
            return "TOTP must be 6-8 digits";
        }
        lock.lock();
        try {
            if (phase == Phase.CANCELLED || phase == Phase.TIMED_OUT) {
                return "Job already cancelled or timed out";
            }
            if (phase != Phase.AWAITING_TOTP) {
                return "No TOTP prompt is currently active";
            }
            currentCode = code;
            phase = Phase.HAS_CODE;
            reason = "";
            reAsk = false;
            deadlineMs = 0L;
            generation++;
            codeReady.signalAll();
            return null;
        } finally {
            lock.unlock();
        }
    }

    public void cancel(String message) {
        lock.lock();
        try {
            phase = Phase.CANCELLED;
            cancelMessage = message != null ? message : "Cancelled";
            currentCode = null;
            reason = cancelMessage;
            deadlineMs = 0L;
            codeReady.signalAll();
        } finally {
            lock.unlock();
        }
    }

    private void startPromptLocked(String promptReason, boolean isReAsk) {
        phase = Phase.AWAITING_TOTP;
        reason = promptReason != null ? promptReason : "Enter your TOTP code to continue SSH.";
        reAsk = isReAsk;
        deadlineMs = System.currentTimeMillis() + DEFAULT_TIMEOUT_MS;
        currentCode = null;
    }

    private String waitForCodeLocked() throws InterruptedException {
        int waitGen = generation;
        while (phase == Phase.AWAITING_TOTP) {
            long remaining = deadlineMs - System.currentTimeMillis();
            if (remaining <= 0) {
                phase = Phase.TIMED_OUT;
                cancelMessage = "TOTP not entered within 60 seconds. Job aborted.";
                reason = cancelMessage;
                currentCode = null;
                codeReady.signalAll();
                return null;
            }
            codeReady.await(remaining, TimeUnit.MILLISECONDS);
            if (phase == Phase.CANCELLED || phase == Phase.TIMED_OUT) {
                return null;
            }
            if (phase == Phase.HAS_CODE && currentCode != null && generation != waitGen) {
                return currentCode;
            }
            if (phase == Phase.HAS_CODE && currentCode != null) {
                return currentCode;
            }
        }
        if (phase == Phase.HAS_CODE) {
            return currentCode;
        }
        return null;
    }
}
