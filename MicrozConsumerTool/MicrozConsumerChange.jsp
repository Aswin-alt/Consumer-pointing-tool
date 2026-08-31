<%@ page language="java" contentType="text/html; charset=UTF-8"
    pageEncoding="UTF-8"%>
<!DOCTYPE html>
<html>
<head>
<meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Microz Consumer Pointing Tool</title>
<link href="css/microz.css" rel="stylesheet" type="text/css" />
</head>
<script src="https://code.jquery.com/jquery-1.10.2.js" type="text/javascript"></script>
<link href="https://cdn.jsdelivr.net/npm/select2@4.0.12/dist/css/select2.min.css" rel="stylesheet" />
<script src="https://cdn.jsdelivr.net/npm/select2@4.0.12/dist/js/select2.min.js"></script>
<script src="js/MicrozAjax.js" type="text/javascript"></script>
<body>
    <div class="page-wrap">
        <header class="hero">
            <h1>Microz Consumer Pointing Tool</h1>
            <p>Enable one or more consumer groups across local app servers</p>
            <button class="admin-gear" id="adminGearBtn" title="Admin Panel">
                <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
                    <path d="M9.95 2H14.05L14.45 4.52C15.08 4.79 15.66 5.15 16.17 5.58L18.58 4.68L20.63 8.23L18.63 9.78C18.71 10.18 18.75 10.59 18.75 11C18.75 11.41 18.71 11.82 18.63 12.22L20.63 13.77L18.58 17.32L16.17 16.42C15.66 16.85 15.08 17.21 14.45 17.48L14.05 20H9.95L9.55 17.48C8.92 17.21 8.34 16.85 7.83 16.42L5.42 17.32L3.37 13.77L5.37 12.22C5.29 11.82 5.25 11.41 5.25 11C5.25 10.59 5.29 10.18 5.37 9.78L3.37 8.23L5.42 4.68L7.83 5.58C8.34 5.15 8.92 4.79 9.55 4.52L9.95 2Z" stroke="url(#gearGrad)" stroke-width="1.8" stroke-linejoin="round"/>
                    <circle cx="12" cy="11" r="3" stroke="url(#gearGrad)" stroke-width="1.8"/>
                    <defs><linearGradient id="gearGrad" x1="3" y1="2" x2="21" y2="20" gradientUnits="userSpaceOnUse"><stop stop-color="#6B6F73"/><stop offset="1" stop-color="#303033"/></linearGradient></defs>
                </svg>
            </button>
        </header>

        <!-- Login Modal -->
        <div class="modal-overlay" id="loginModal">
            <div class="modal-card">
                <div class="modal-logo">
                    <div class="modal-logo-icon">
                        <svg width="32" height="32" viewBox="0 0 24 24" fill="none">
                            <path d="M12 2L4 5.5V11.5C4 16.2 7.4 20.6 12 22C16.6 20.6 20 16.2 20 11.5V5.5L12 2Z" fill="url(#shieldGrad)" stroke="url(#shieldStroke)" stroke-width="1"/>
                            <rect x="10" y="10" width="4" height="5" rx="1" fill="#fff"/>
                            <circle cx="12" cy="9" r="2" fill="none" stroke="#fff" stroke-width="1.5"/>
                            <defs>
                                <linearGradient id="shieldGrad" x1="4" y1="2" x2="20" y2="22" gradientUnits="userSpaceOnUse">
                                    <stop stop-color="#0a84ff"/>
                                    <stop offset="1" stop-color="#5e5ce6"/>
                                </linearGradient>
                                <linearGradient id="shieldStroke" x1="4" y1="2" x2="20" y2="22" gradientUnits="userSpaceOnUse">
                                    <stop stop-color="#3a9fff"/>
                                    <stop offset="1" stop-color="#7d7aff"/>
                                </linearGradient>
                            </defs>
                        </svg>
                    </div>
                    <h3>Admin Login</h3>
                    <p class="modal-subtitle">Authenticate to manage server configurations</p>
                </div>
                <div class="modal-field">
                    <label class="modal-label">Username</label>
                    <input type="text" id="adminUser" class="modal-input" autocomplete="username" />
                </div>
                <div class="modal-field">
                    <label class="modal-label">Password</label>
                    <input type="password" id="adminPass" class="modal-input" autocomplete="current-password" />
                </div>
                <div id="loginError" class="modal-error"></div>
                <div class="modal-actions">
                    <button class="modal-btn secondary" id="loginCancelBtn">Cancel</button>
                    <button class="modal-btn primary" id="loginSubmitBtn">Sign In</button>
                </div>
            </div>
        </div>

        <!-- Admin Panel -->
        <section class="panel admin-panel" id="adminPanel" style="display:none;">
            <div class="admin-header">
                <h2>Admin Control Panel</h2>
                <button class="admin-logout-btn" id="adminLogoutBtn">Sign Out</button>
            </div>

            <!-- Tabs -->
            <div class="admin-tabs">
                <button class="admin-tab active" data-tab="appservers">App Servers</button>
                <button class="admin-tab" data-tab="consumers">Consumers</button>
            </div>

            <!-- App Servers Tab -->
            <div class="admin-tab-content active" id="tab-appservers">
                <div class="admin-add-row">
                    <input type="text" class="admin-input" id="newAppKey" placeholder="Server name (e.g. deskplus11)" />
                    <input type="text" class="admin-input wide" id="newAppValue" placeholder="IPs comma-separated (e.g. 10.0.0.1,10.0.0.2)" />
                    <button class="admin-action-btn add" id="addAppBtn">Add</button>
                </div>
                <div class="admin-table-wrap" id="appServerTable"></div>
            </div>

            <!-- Consumers Tab -->
            <div class="admin-tab-content" id="tab-consumers">
                <div class="admin-add-row">
                    <input type="text" class="admin-input" id="newConKey" placeholder="Consumer name" />
                    <input type="text" class="admin-input wide" id="newConValue" placeholder="Value (e.g. &quot;microz.consumer...&quot;,&quot;&quot;)" />
                    <button class="admin-action-btn add" id="addConBtn">Add</button>
                </div>
                <div class="admin-table-wrap" id="consumerTable"></div>
            </div>
        </section>

        <main class="config-grid">
            <section class="panel form-panel">
                <h2>Consumer Configuration</h2>
                <div class="formInput totp-field">
                    <label class="formLabel" for="totpCode">TOTP Code</label>
                    <input type="text" id="totpCode" class="totp-input" inputmode="numeric" pattern="[0-9]*" maxlength="8" autocomplete="one-time-code" placeholder="Enter 6-digit code" />
                    <div class="tip">Required for every enable operation. Enter your current authenticator code.</div>
                </div>
                <div class="formContainer microz-form" id="formData"></div>
            </section>
            <section class="panel result-panel">
                <h2>Execution Result</h2>
                <div id="responseContainer" class="responseContainer"></div>
            </section>
        </main>
    </div>
</body>
</html>