extends Node
## NimiqJS — All JavaScript bridge operations run through this singleton.
## Because { } characters cause issues in GDScript triple-quote strings,
## all JS code has been moved here.

# ── requestAccount ────────────────────────────────────────────────────────────
## Requests account connection via window.nimiq.
## Result is written to window._nimiqAccountRequest.
func start_request_account() -> void:
	# Real API: listAccounts() → string[]
	# No account → call connect(), user selects, then listAccounts
	if not OS.has_feature("web"):
		return
	var js : String = (
		"(function(){"
		+ "window._nimiqAccountRequest = null;"
		+ "if(!window.nimiq){"
		+   "window._nimiqAccountRequest={ok:false,err:'no_provider'}; return;"
		+ "}"
		+ "function finish(addr){"
		+   "window._nimiqAccountRequest = addr"
		+     "? {ok:true, address:String(addr), label:String(addr).slice(0,9)}"
		+     ": {ok:false, err:'no_account'};"
		+ "}"
		+ "function doList(){"
		+   "return window.nimiq.listAccounts().then(function(r){"
		+     "if(Array.isArray(r) && r.length>0 && typeof r[0]==='string') return r[0];"
		+     "return null;"
		+   "});"
		+ "}"
		+ "doList().then(function(addr){"
		+   "if(addr){ finish(addr); return; }"
		# No account → call connect(), user selects, then listAccounts
		+   "window.nimiq.connect().then(function(){"
		+     "return doList();"
		+   "}).then(function(addr2){"
		+     "finish(addr2);"
		+   "}).catch(function(e){"
		+     "window._nimiqAccountRequest={ok:false,err:String(e)};"
		+   "});"
		+ "}).catch(function(e){"
		+   "window._nimiqAccountRequest={ok:false,err:String(e)};"
		+ "});"
		+ "})();"
	)
	JavaScriptBridge.eval(js, true)


## Waits for result after start_request_account() is called.
## Returns: {ok, address, label} or {ok:false, err}
## Timeout: timeout_sec seconds
func await_request_account(timeout_sec: float = 30.0) -> Dictionary:
	var steps := int(timeout_sec * 10)
	var j := JSON.new()   # NJ-01: allocate once, reuse per poll
	for _i in steps:
		await get_tree().create_timer(0.1).timeout
		var raw = JavaScriptBridge.eval("window._nimiqAccountRequest", true)
		if raw == null:
			continue
		var raw_str := str(JavaScriptBridge.eval("JSON.stringify(window._nimiqAccountRequest)", true))
		if j.parse(raw_str) != OK:
			break
		var d : Dictionary = j.get_data()
		return d
	return {ok = false, err = "timeout"}


## Shortcut: request + wait (coroutine)
func request_account(timeout_sec: float = 30.0) -> Dictionary:
	start_request_account()
	var result := await await_request_account(timeout_sec)
	# BUG FIX: every "Connect Wallet" button in the game (StatsPanel,
	# QuestPanel, LeaderboardPanel) and the Play-button wallet flow all
	# funnel through this one function — and when there's genuinely no
	# provider (window.nimiq doesn't exist, i.e. the page isn't running
	# inside Nimiq Pay), this used to just return {ok:false, err:'no_provider'}
	# with zero visible feedback: the button flips back to "Connect Wallet"
	# and nothing else happens, which looks broken/dead rather than "you need
	# to open this in the app." Same install popup the "Open ↗" banner button
	# already shows (see index.html's showInstallPopup) — one popup, one
	# consistent message, triggered from the single chokepoint instead of
	# patching each panel separately.
	if not result.get("ok", false) and str(result.get("err", "")) == "no_provider":
		JavaScriptBridge.eval("if(window._showNimiqInstallPopup) window._showNimiqInstallPopup();", true)
	return result


# ── Provider method discovery ─────────────────────────────────────────────────
## Logs methods on window.nimiq (for debugging).
func log_provider_keys() -> void:
	if not OS.has_feature("web"):
		return
	JavaScriptBridge.eval(
		"console.log('[NimiqJS] provider keys:', window.nimiq ? Object.keys(window.nimiq).join(', ') : 'no provider')",
		true
	)


# ── Sign ──────────────────────────────────────────────────────────────────────
## window.nimiq.sign(challenge) — writes result to DOM dataset (Emscripten async callback workaround)
func start_sign(challenge: String) -> void:
	if not OS.has_feature("web"):
		return
	# DOM dataset kullan: async callback da buraya yazabilir, eval da okuyabilir
	var js : String = (
		"(function(){"
		+ "document.body.dataset.nimiqSign = '';"
		+ "var _prov = window.nimiq || (window._nimiqData && window._nimiqData._provider);"
		+ "if(!_prov){"
		+   "document.body.dataset.nimiqSign = JSON.stringify({ok:false,err:'no_provider'});"
		+   "return;"
		+ "}"
		+ "_prov.sign('" + challenge + "')"
		+   ".then(function(r){"
		+     "document.body.dataset.nimiqSign = JSON.stringify({ok:true,publicKey:r.publicKey,signature:r.signature});"
		+     "console.log('[sign] DOM written ok publicKey='+r.publicKey.slice(0,8)+' siglen='+r.signature.length);"
		+   "}).catch(function(e){"
		+     "var _em=e&&e.message?e.message:(typeof e==='string'?e:JSON.stringify(e)||'rejected');"
		+     "document.body.dataset.nimiqSign = JSON.stringify({ok:false,err:_em});"
		+     "console.log('[sign] DOM written err='+_em);"
		+   "});"
		+ "})();"
	)
	JavaScriptBridge.eval(js, true)


## Waits for start_sign() result. timeout_sec: enough time for user to approve in Nimiq Pay.
func await_sign(timeout_sec: float = 60.0) -> Dictionary:
	var steps := int(timeout_sec * 10)
	var j := JSON.new()   # NJ-02: allocate once, reuse per poll
	for _i in steps:
		await get_tree().create_timer(0.1).timeout
		var raw_str = JavaScriptBridge.eval("document.body.dataset.nimiqSign || ''", true)
		if raw_str == null:
			continue
		var s := str(raw_str).strip_edges()
		if s == "" or s == "null":
			continue
		# Clear so old value isn't read on second call
		JavaScriptBridge.eval("document.body.dataset.nimiqSign = ''", true)
		if j.parse(s) == OK:
			return j.get_data()
	return {ok = false, err = "timeout"}


# ── Hub API sign (web browser, outside Nimiq Pay) ───────────────────────────
## window._nimiqHubSign(challenge) — real Nimiq wallet sign-in via the Nimiq
## Hub API popup (hub.nimiq.com), for players in a plain browser tab where
## window.nimiq (the mini-app SDK, see start_sign() above) never gets set.
## Same DOM-dataset async-callback pattern as start_sign()/await_sign().
##
## IMPORTANT: MUST be called synchronously from a real user gesture (a
## button's pressed handler) — Hub API opens a popup, and popups opened
## outside a user gesture get blocked by the browser. Never call this from a
## background/silent auto-sign attempt. In practice this is reached from a
## Play/Connect button's pressed handler, which runs within the same input
## frame as the tap, i.e. still inside the browser's ~5s transient-activation
## window — so window.open() is permitted. The eager module preload in
## index.html ensures signMessage() (and its window.open()) then runs with no
## async gap. The "Invalid Request"/"Connection was closed" error this whole
## flow used to hit was NEVER a gesture problem — it was cross-origin
## isolation (COOP/COEP) severing the popup's window.opener, fixed in the
## _headers file. See that file's doc comment for the full story.
func start_hub_sign(challenge: String) -> void:
	if not OS.has_feature("web"):
		return
	document_dataset_clear("nimiqHubSign")
	# JSON.stringify (not naive string concatenation) so this is safe
	# regardless of the challenge's exact contents — even though in practice
	# NewChallenge()'s format (backend/game/auth.go) is always plain ASCII.
	var js_literal := JSON.stringify(challenge)
	JavaScriptBridge.eval(
		"if(window._nimiqHubSign) window._nimiqHubSign(" + js_literal + ");",
		true
	)


## Waits for start_hub_sign() result. timeout_sec: enough time for the user to
## pick an account and approve in the Hub API popup.
## Returns: {ok:true, address, publicKey, signature} or {ok:false, err}
func await_hub_sign(timeout_sec: float = 90.0) -> Dictionary:
	var steps := int(timeout_sec * 10)
	var j := JSON.new()
	for _i in steps:
		await get_tree().create_timer(0.1).timeout
		var raw_str = JavaScriptBridge.eval("document.body.dataset.nimiqHubSign || ''", true)
		if raw_str == null:
			continue
		var s := str(raw_str).strip_edges()
		if s == "" or s == "null":
			continue
		document_dataset_clear("nimiqHubSign")
		if j.parse(s) == OK:
			return j.get_data()
	return {ok = false, err = "timeout"}


## Shortcut: request + wait (coroutine).
## Returns: {ok:true, address, publicKey, signature} or {ok:false, err}
func request_hub_sign(challenge: String, timeout_sec: float = 90.0) -> Dictionary:
	start_hub_sign(challenge)
	return await await_hub_sign(timeout_sec)


# ── Payment (VS room entry fee) ─────────────────────────────────────────────
## Sends a NIM payment and writes the result to document.body.dataset.nimiqPay
## as {ok:true, tx:"<hash>"} or {ok:false, err}. value is in luna (1 NIM =
## 100000 luna, matches NimLunaMultiplier backend-side). data is the short
## "vs:<room_id>:<c|o>" memo tag the backend matches the incoming payment
## against — see backend/game/vsroom.go.
##
## Two channels, chosen at runtime:
##   • Inside Nimiq Pay — the mini-app SDK's
##     window.nimiq.sendBasicTransactionWithData() (native wallet UI).
##   • Plain web browser (no window.nimiq) — the Hub API checkout() popup
##     (window._nimiqHubCheckout in index.html). This is the fix for
##     "payment failed: no_provider" on web: outside Nimiq Pay there is no
##     window.nimiq, so we route through the same Hub popup channel web
##     sign-in uses instead of failing. MUST be reached synchronously from a
##     real button-press gesture so the popup isn't blocked (see _do_pay).
## JSON.stringify() is used for recipient/data so the injected JS is safe
## regardless of their contents (defense-in-depth; both are plain ASCII here).
func start_payment(recipient: String, value_luna: int, data: String) -> void:
	if not OS.has_feature("web"):
		return
	document_dataset_clear("nimiqPay")
	var rcpt := JSON.stringify(recipient)
	var memo := JSON.stringify(data)
	var js : String = (
		"(function(){"
		+ "document.body.dataset.nimiqPay = '';"
		+ "var _prov = window.nimiq || (window._nimiqData && window._nimiqData._provider);"
		+ "if(_prov){"
		+   "_prov.sendBasicTransactionWithData({"
		+     "recipient:" + rcpt + ","
		+     "value:" + str(value_luna) + ","
		+     "data:" + memo
		+   "})"
		+     ".then(function(r){"
		+       "if(r && r.error){"
		+         "document.body.dataset.nimiqPay = JSON.stringify({ok:false,err:(r.error.message||'rejected')});"
		+         "return;"
		+       "}"
		+       "document.body.dataset.nimiqPay = JSON.stringify({ok:true,tx:String(r)});"
		+     "}).catch(function(e){"
		+       "var _em=e&&e.message?e.message:(typeof e==='string'?e:JSON.stringify(e)||'rejected');"
		+       "document.body.dataset.nimiqPay = JSON.stringify({ok:false,err:_em});"
		+     "});"
		+   "return;"
		+ "}"
		# No mini-app provider → plain web browser → Hub API checkout popup.
		+ "if(window._nimiqHubCheckout){"
		+   "window._nimiqHubCheckout(" + rcpt + "," + str(value_luna) + "," + memo + ");"
		+   "return;"
		+ "}"
		+ "document.body.dataset.nimiqPay = JSON.stringify({ok:false,err:'no_provider'});"
		+ "})();"
	)
	JavaScriptBridge.eval(js, true)


## Waits for start_payment() result. timeout_sec: enough time for the user to
## approve the payment in their Nimiq Pay wallet UI.
## Returns: {ok:true, tx:"<serialized_tx_hex_or_hash>"} or {ok:false, err}
func await_payment(timeout_sec: float = 90.0) -> Dictionary:
	var steps := int(timeout_sec * 10)
	var j := JSON.new()
	for _i in steps:
		await get_tree().create_timer(0.1).timeout
		var raw_str = JavaScriptBridge.eval("document.body.dataset.nimiqPay || ''", true)
		if raw_str == null:
			continue
		var s := str(raw_str).strip_edges()
		if s == "" or s == "null":
			continue
		document_dataset_clear("nimiqPay")
		if j.parse(s) == OK:
			return j.get_data()
	return {ok = false, err = "timeout"}


## Shortcut: send + wait (coroutine)
func request_payment(recipient: String, value_luna: int, data: String, timeout_sec: float = 90.0) -> Dictionary:
	start_payment(recipient, value_luna, data)
	return await await_payment(timeout_sec)


func document_dataset_clear(key: String) -> void:
	if not OS.has_feature("web"):
		return
	JavaScriptBridge.eval("document.body.dataset." + key + " = ''", true)


## Web canvas'ı focus'la — LineEdit input'tan önce çağır
func focus_canvas() -> void:
	if not OS.has_feature("web"):
		return
	JavaScriptBridge.eval(
		"(function(){"
		+ "var c = Module.canvas || document.querySelector('canvas');"
		+ "if(c){"
		+   "c.setAttribute('tabindex','0');"
		+   "c.focus();"
		+ "}"
		+ "})()", true)
