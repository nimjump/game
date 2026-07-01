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
	return await await_request_account(timeout_sec)


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
