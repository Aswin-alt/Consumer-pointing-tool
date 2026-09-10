$(document).ready(function() {
	$.ajax({
		url: "MicrozConsumerChange",
		data: {
			action: "loadAppServerIp"
		},
		success: function(responseText) {
			$("#formData").html(responseText);

			var appServerName = $("#formData").find("#AppServerName");
			if (appServerName && appServerName.length > 0) {
				appServerName.select2({
					width: "100%",
					placeholder: "Select app server"
				});
			}

			var consumerName = $("#formData").find("#ConsumerName");
			if (consumerName && consumerName.length > 0) {
				consumerName.select2({
					width: "100%",
					placeholder: "Select one or more consumers"
				});
			}

			$("#enableBtn").on("click", enableConsumer);
		}
	});
});

function escapeHtml(str) {
	return String(str)
		.replace(/&/g, "&amp;")
		.replace(/</g, "&lt;")
		.replace(/>/g, "&gt;")
		.replace(/\"/g, "&quot;")
		.replace(/'/g, "&#39;");
}

function renderResult(data) {
	var successCount = 0;
	var rows = "";

	$.each(data.results || [], function(_, item) {
		var ok = !!item.success;
		if (ok) {
			successCount++;
		}
		rows += "<tr>"
			+ "<td>" + escapeHtml(item.consumer) + "</td>"
			+ "<td><span class='badge " + (ok ? "ok" : "fail") + "'>" + (ok ? "Enabled" : "Failed") + "</span></td>"
			+ "<td>" + escapeHtml(item.message || "") + "</td>"
			+ "</tr>";
	});

	var total = (data.results || []).length;
	var toastClass = successCount === total ? "ok" : "fail";
	var toast = "<div class='toast " + toastClass + "'>"
		+ "AppServer: " + escapeHtml(data.appServer || "")
		+ " | Consumers succeeded: " + successCount + "/" + total
		+ "</div>";

	var table = "<table class='result-table'>"
		+ "<thead><tr><th>Consumer</th><th>Status</th><th>Summary</th></tr></thead>"
		+ "<tbody>" + rows + "</tbody>"
		+ "</table>";

	$("#responseContainer").html(toast + table);
}

function enableConsumer() {
	var appServerName = $("#AppServerName").val();
	var consumerNames = $("#ConsumerName").val() || [];
	var $btn = $("#enableBtn");

	if (!appServerName) {
		$("#responseContainer").html("<div class='toast fail'>Please select an app server.</div>");
		return;
	}

	if (!consumerNames.length) {
		$("#responseContainer").html("<div class='toast fail'>Please select at least one consumer.</div>");
		return;
	}

	$btn.prop("disabled", true).html("<span class='spinner'></span>Enabling...");
	$("#responseContainer").html("<div class='toast'>Starting enable job...</div>");

	$.ajax({
		url: "MicrozConsumerChange",
		type: "POST",
		traditional: true,
		dataType: "json",
		data: {
			action: "startEnable",
			AppServerName: appServerName,
			ConsumerName: consumerNames
		},
		success: function(resp) {
			if (!resp || !resp.success || !resp.jobId) {
				$("#responseContainer").html("<div class='toast fail'>" + escapeHtml((resp && resp.message) || "Failed to start job") + "</div>");
				$btn.prop("disabled", false).text("Enable Consumers");
				return;
			}
			pollEnableJob(resp.jobId, $btn);
		},
		error: function(xhr) {
			var msg = "Unexpected error while starting enable job.";
			if (xhr && xhr.responseText) {
				msg = xhr.responseText;
			}
			$("#responseContainer").html("<div class='toast fail'>" + escapeHtml(msg) + "</div>");
			$btn.prop("disabled", false).text("Enable Consumers");
		}
	});
}

var _enablePollTimer = null;
var _totpCountdownTimer = null;
var _activeJobId = null;
var _totpModalVisible = false;

function stopEnablePolling() {
	if (_enablePollTimer) {
		clearInterval(_enablePollTimer);
		_enablePollTimer = null;
	}
}

function stopTotpCountdown() {
	if (_totpCountdownTimer) {
		clearInterval(_totpCountdownTimer);
		_totpCountdownTimer = null;
	}
}

function hideTotpModal() {
	$("#totpModal").removeClass("visible");
	$("#totpModalInput").val("");
	$("#totpModalError").text("");
	$("#totpCountdown").hide().text("");
	stopTotpCountdown();
	_totpModalVisible = false;
}

function showTotpModal(reason, secondsRemaining, isReAsk) {
	$("#totpModalReason").text(reason || "Enter your authenticator code to continue.");
	$("#totpModalTitle").text(isReAsk ? "TOTP Re-entry Required" : "SSH TOTP Required");
	$("#totpModalError").text("");
	$("#totpModal").addClass("visible");
	if (!_totpModalVisible) {
		$("#totpModalInput").val("").focus();
	}
	_totpModalVisible = true;

	stopTotpCountdown();
	var secs = typeof secondsRemaining === "number" ? secondsRemaining : 60;
	function paintCountdown(s) {
		$("#totpCountdown")
			.show()
			.html("Time remaining: <strong>" + s + "s</strong>");
	}
	paintCountdown(secs);
	_totpCountdownTimer = setInterval(function() {
		secs -= 1;
		if (secs <= 0) {
			paintCountdown(0);
			stopTotpCountdown();
			return;
		}
		paintCountdown(secs);
	}, 1000);
}

function finishEnableJob($btn, statusData) {
	stopEnablePolling();
	hideTotpModal();
	_activeJobId = null;
	$btn.prop("disabled", false).text("Enable Consumers");

	if (statusData && statusData.payload) {
		renderResult(statusData.payload);
		return;
	}

	var msg = (statusData && statusData.message) || "Enable job failed.";
	$("#responseContainer").html("<div class='toast fail'>" + escapeHtml(msg) + "</div>");
}

function pollEnableJob(jobId, $btn) {
	_activeJobId = jobId;
	stopEnablePolling();

	function tick() {
		$.ajax({
			url: "MicrozConsumerChange",
			dataType: "json",
			data: { action: "jobStatus", jobId: jobId },
			success: function(st) {
				if (!st || !st.success) {
					finishEnableJob($btn, { message: (st && st.message) || "Lost job status" });
					return;
				}

				if (st.status === "done") {
					finishEnableJob($btn, st);
					return;
				}

				if (st.status === "failed") {
					finishEnableJob($btn, st);
					return;
				}

				if (st.needsTotp) {
					showTotpModal(st.totpReason, st.totpSecondsRemaining, !!st.totpReAsk);
					$("#responseContainer").html("<div class='toast'>Waiting for TOTP...</div>");
				} else {
					if (_totpModalVisible) {
						hideTotpModal();
					}
					$("#responseContainer").html("<div class='toast'>Running SSH enable on hosts...</div>");
				}
			},
			error: function() {
				finishEnableJob($btn, { message: "Failed to poll job status" });
			}
		});
	}

	tick();
	_enablePollTimer = setInterval(tick, 1000);
}

$(document).on("click", "#totpSubmitBtn", function() {
	var code = ($("#totpModalInput").val() || "").trim();
	$("#totpModalError").text("");
	if (!/^\d{6,8}$/.test(code)) {
		$("#totpModalError").text("Enter a valid 6–8 digit TOTP.");
		return;
	}
	if (!_activeJobId) {
		$("#totpModalError").text("No active job.");
		return;
	}

	var $submit = $("#totpSubmitBtn").prop("disabled", true).text("Submitting...");
	$.ajax({
		url: "MicrozConsumerChange",
		type: "POST",
		dataType: "json",
		data: { action: "submitTotp", jobId: _activeJobId, totp: code },
		success: function(r) {
			if (r && r.success) {
				$("#totpModalInput").val("");
				$("#totpModalError").text("");
				// Keep modal until status clears needsTotp; countdown stops on next poll
			} else {
				$("#totpModalError").text((r && r.message) || "Failed to submit TOTP");
			}
		},
		error: function() {
			$("#totpModalError").text("Connection error while submitting TOTP");
		},
		complete: function() {
			$submit.prop("disabled", false).text("Submit");
		}
	});
});

$(document).on("keydown", "#totpModalInput", function(e) {
	if (e.which === 13) {
		$("#totpSubmitBtn").click();
	}
});

$(document).on("click", "#totpCancelBtn", function() {
	if (!_activeJobId) {
		hideTotpModal();
		return;
	}
	var jobId = _activeJobId;
	var $btn = $("#enableBtn");
	$.ajax({
		url: "MicrozConsumerChange",
		type: "POST",
		dataType: "json",
		data: { action: "cancelJob", jobId: jobId },
		complete: function() {
			finishEnableJob($btn, { message: "Cancelled by user" });
		}
	});
});

/* ═══════════════════════════════════════════════════════════════════════
   Admin Panel Logic
   ═══════════════════════════════════════════════════════════════════════ */

(function() {
	var adminData = null;

	// Check session on load
	$.ajax({
		url: "MicrozConsumerChange",
		data: { action: "adminCheck" },
		dataType: "json",
		success: function(r) {
			if (r && r.loggedIn) showAdminPanel();
		}
	});

	// Gear button
	$(document).on("click", "#adminGearBtn", function() {
		// Check if already logged in
		$.ajax({
			url: "MicrozConsumerChange",
			data: { action: "adminCheck" },
			dataType: "json",
			success: function(r) {
				if (r && r.loggedIn) {
					showAdminPanel();
				} else {
					$("#loginModal").addClass("visible");
					$("#adminUser").focus();
				}
			}
		});
	});

	// Cancel login
	$(document).on("click", "#loginCancelBtn", function() {
		closeLoginModal();
	});
	$(document).on("click", "#loginModal", function(e) {
		if (e.target === this) closeLoginModal();
	});

	// Submit login
	$(document).on("click", "#loginSubmitBtn", doLogin);
	$(document).on("keydown", "#adminPass, #adminUser", function(e) {
		if (e.which === 13) doLogin();
	});

	function doLogin() {
		var user = $("#adminUser").val().trim();
		var pass = $("#adminPass").val().trim();
		$("#loginError").text("");

		if (!user || !pass) {
			$("#loginError").text("Please enter both fields.");
			return;
		}

		$("#loginSubmitBtn").prop("disabled", true).text("Signing in...");

		$.ajax({
			url: "MicrozConsumerChange",
			type: "POST",
			dataType: "json",
			data: { action: "adminLogin", username: user, password: pass },
			success: function(r) {
				if (r && r.success) {
					closeLoginModal();
					showAdminPanel();
				} else {
					$("#loginError").text(r.message || "Login failed.");
				}
			},
			error: function() {
				$("#loginError").text("Connection error.");
			},
			complete: function() {
				$("#loginSubmitBtn").prop("disabled", false).text("Sign In");
			}
		});
	}

	function closeLoginModal() {
		$("#loginModal").removeClass("visible");
		$("#adminUser, #adminPass").val("");
		$("#loginError").text("");
	}

	// Logout
	$(document).on("click", "#adminLogoutBtn", function() {
		$.ajax({
			url: "MicrozConsumerChange",
			type: "POST",
			data: { action: "adminLogout" },
			dataType: "json",
			complete: function() {
				$("#adminPanel").slideUp(300);
				adminData = null;
			}
		});
	});

	function showAdminPanel() {
		$("#adminPanel").slideDown(300);
		loadAdminData();
	}

	function loadAdminData() {
		$.ajax({
			url: "MicrozConsumerChange",
			data: { action: "loadAdminData" },
			dataType: "json",
			success: function(data) {
				adminData = data;
				renderAdminTable("appservers", data.appservers, "#appServerTable");
				renderAdminTable("consumers", data.consumers, "#consumerTable");
			},
			error: function() {
				$("#appServerTable").html("<p class='admin-empty'>Failed to load data.</p>");
			}
		});
	}

	function renderAdminTable(type, entries, container) {
		if (!entries || Object.keys(entries).length === 0) {
			$(container).html("<p class='admin-empty'>No entries found.</p>");
			return;
		}

		var keys = Object.keys(entries).sort();
		var html = "<table class='admin-data-table'>"
			+ "<thead><tr><th>Name</th><th>Value</th><th></th></tr></thead><tbody>";

		for (var i = 0; i < keys.length; i++) {
			var k = keys[i];
			html += "<tr>"
				+ "<td class='admin-key'>" + escapeHtml(k) + "</td>"
				+ "<td><input class='admin-edit-input' data-type='" + type + "' data-key='" + escapeHtml(k) + "' value='" + escapeHtml(entries[k]) + "' /></td>"
				+ "<td class='admin-actions'>"
				+ "<button class='admin-action-btn save' data-type='" + type + "' data-key='" + escapeHtml(k) + "'>Save</button>"
				+ "<button class='admin-action-btn delete' data-type='" + type + "' data-key='" + escapeHtml(k) + "'>Delete</button>"
				+ "</td></tr>";
		}

		html += "</tbody></table>";
		$(container).html(html);
	}

	// Tabs
	$(document).on("click", ".admin-tab", function() {
		$(".admin-tab").removeClass("active");
		$(this).addClass("active");
		$(".admin-tab-content").removeClass("active");
		$("#tab-" + $(this).data("tab")).addClass("active");
	});

	// Save existing entry
	$(document).on("click", ".admin-action-btn.save", function() {
		var type = $(this).data("type");
		var key = $(this).data("key");
		var $input = $("input.admin-edit-input[data-key='" + key + "'][data-type='" + type + "']");
		var value = $input.val();
		var action = type === "appservers" ? "saveAppServer" : "saveConsumer";
		var $btn = $(this);

		$btn.prop("disabled", true).text("...");
		$.ajax({
			url: "MicrozConsumerChange",
			type: "POST",
			dataType: "json",
			data: { action: action, key: key, value: value },
			success: function(r) {
				if (r && r.success) {
					$btn.text("\u2713").addClass("saved");
					setTimeout(function() { $btn.text("Save").removeClass("saved"); }, 1200);
					reloadFormData();
				} else {
					$btn.text("Error");
					setTimeout(function() { $btn.text("Save"); }, 1200);
				}
			},
			complete: function() { $btn.prop("disabled", false); }
		});
	});

	// Delete entry
	$(document).on("click", ".admin-action-btn.delete", function() {
		var type = $(this).data("type");
		var key = $(this).data("key");
		if (!confirm("Delete \"" + key + "\"?")) return;
		var action = type === "appservers" ? "deleteAppServer" : "deleteConsumer";
		var $btn = $(this);

		$btn.prop("disabled", true).text("...");
		$.ajax({
			url: "MicrozConsumerChange",
			type: "POST",
			dataType: "json",
			data: { action: action, key: key },
			success: function(r) {
				if (r && r.success) {
					$btn.closest("tr").fadeOut(300, function() { $(this).remove(); });
					reloadFormData();
				} else {
					$btn.text("Error");
					setTimeout(function() { $btn.text("Delete"); }, 1200);
				}
			},
			complete: function() { $btn.prop("disabled", false); }
		});
	});

	// Add new app server
	$(document).on("click", "#addAppBtn", function() {
		var key = $("#newAppKey").val().trim();
		var value = $("#newAppValue").val().trim();
		if (!key) return;
		var $btn = $(this);
		$btn.prop("disabled", true).text("...");
		$.ajax({
			url: "MicrozConsumerChange", type: "POST", dataType: "json",
			data: { action: "saveAppServer", key: key, value: value },
			success: function(r) {
				if (r && r.success) {
					$("#newAppKey, #newAppValue").val("");
					loadAdminData();
					reloadFormData();
				}
			},
			complete: function() { $btn.prop("disabled", false).text("Add"); }
		});
	});

	// Add new consumer
	$(document).on("click", "#addConBtn", function() {
		var key = $("#newConKey").val().trim();
		var value = $("#newConValue").val().trim();
		if (!key) return;
		var $btn = $(this);
		$btn.prop("disabled", true).text("...");
		$.ajax({
			url: "MicrozConsumerChange", type: "POST", dataType: "json",
			data: { action: "saveConsumer", key: key, value: value },
			success: function(r) {
				if (r && r.success) {
					$("#newConKey, #newConValue").val("");
					loadAdminData();
					reloadFormData();
				}
			},
			complete: function() { $btn.prop("disabled", false).text("Add"); }
		});
	});

	// Reload the main form dropdowns after admin edits
	function reloadFormData() {
		$.ajax({
			url: "MicrozConsumerChange",
			data: { action: "loadAppServerIp" },
			success: function(responseText) {
				$("#formData").html(responseText);
				$("#AppServerName").select2({ width: "100%", placeholder: "Select app server" });
				$("#ConsumerName").select2({ width: "100%", placeholder: "Select one or more consumers" });
				$("#enableBtn").on("click", enableConsumer);
			}
		});
	}
})();