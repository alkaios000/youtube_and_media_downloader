package com.linkdrop.linkdrop_downloader

import android.annotation.SuppressLint
import android.app.Activity
import android.app.Dialog
import android.content.Context
import android.graphics.Color
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import java.io.File
import java.util.Collections
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONObject

class WebViewMediaSniffer(private val context: Context) {
    companion object {
        private const val TAG = "WebViewMediaSniffer"
        private const val MOBILE_IOS_UA =
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) " +
                "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1"
        private const val MOBILE_ANDROID_UA =
            "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    @SuppressLint("SetJavaScriptEnabled")
    fun sniffMedia(
        activity: Activity,
        url: String,
        platform: String,
        timeoutMs: Long = 16000L,
        onResult: (Map<String, Any?>) -> Unit,
        onError: (String, String) -> Unit,
    ) {
        mainHandler.post {
            val finished = AtomicBoolean(false)
            val capturedVideos = Collections.synchronizedSet(LinkedHashSet<String>())
            val capturedImages = Collections.synchronizedSet(LinkedHashSet<String>())
            var finalLoadedUrl = url
            var pageTitle = ""
            var pageAuthor = ""
            var pageThumb = ""
            var pageLoaded = false

            val lowerInput = url.lowercase()
            val isStrictVideoUrl = (platform.equals("instagram", ignoreCase = true) &&
                (lowerInput.contains("/reel/") || lowerInput.contains("/reels/") || lowerInput.contains("/tv/"))) ||
                (platform.equals("facebook", ignoreCase = true) &&
                    (lowerInput.contains("/reel/") || lowerInput.contains("/watch") || lowerInput.contains("/videos/")))

            val userAgent = if (platform.equals("douyin", ignoreCase = true)) {
                MOBILE_IOS_UA
            } else {
                MOBILE_ANDROID_UA
            }

            val rootContainer = activity.window?.decorView as? ViewGroup
            val webView = try {
                WebView(activity)
            } catch (t: Throwable) {
                onError("WEBVIEW_ERROR", "WebView tidak tersedia di perangkat ini: ${t.message}")
                return@post
            }

            val holder = FrameLayout(activity).apply {
                alpha = 0f
                isClickable = false
                isFocusable = false
                addView(
                    webView,
                    FrameLayout.LayoutParams(1080, 1920),
                )
            }
            rootContainer?.addView(holder, ViewGroup.LayoutParams(1, 1))

            fun cleanup() {
                mainHandler.post {
                    runCatching {
                        webView.stopLoading()
                        webView.webViewClient = WebViewClient()
                        webView.webChromeClient = null
                        webView.loadUrl("about:blank")
                        rootContainer?.removeView(holder)
                        webView.destroy()
                    }
                }
            }

            fun completeNow() {
                if (!finished.compareAndSet(false, true)) return
                val cookies = runCatching {
                    CookieManager.getInstance().flush()
                    collectCookieHeader(finalLoadedUrl, url, platform)
                }.getOrDefault("")
                exportAllCookiesToNetscapeFile()

                val videos = synchronized(capturedVideos) { capturedVideos.toList() }
                // For strict video URLs (like Instagram Reels), NEVER return cover images if no video found!
                val images = if (isStrictVideoUrl && videos.isEmpty()) {
                    emptyList()
                } else {
                    synchronized(capturedImages) { capturedImages.toList() }
                }
                cleanup()

                if (videos.isEmpty() && images.isEmpty()) {
                    val hint = if (isStrictVideoUrl) {
                        "Stream video Reel tidak ditemukan tanpa login. Coba Login Browser di menu Pengaturan lalu ulangi."
                    } else {
                        "Tidak menemukan stream video/foto di halaman ini. Konten mungkin memerlukan login (coba Login Browser di Pengaturan)."
                    }
                    onError("SNIFF_EMPTY", hint)
                } else {
                    onResult(
                        mapOf(
                            "finalUrl" to finalLoadedUrl,
                            "title" to pageTitle,
                            "author" to pageAuthor,
                            "thumbnail" to pageThumb,
                            "videos" to videos,
                            "images" to images,
                            "cookies" to cookies,
                            "userAgent" to userAgent,
                        ),
                    )
                }
            }

            try {
                val cookieManager = CookieManager.getInstance()
                cookieManager.setAcceptCookie(true)
                cookieManager.setAcceptThirdPartyCookies(webView, true)

                webView.settings.apply {
                    javaScriptEnabled = true
                    domStorageEnabled = true
                    databaseEnabled = true
                    mediaPlaybackRequiresUserGesture = false
                    loadsImagesAutomatically = true
                    mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
                    userAgentString = userAgent
                    cacheMode = WebSettings.LOAD_DEFAULT
                    useWideViewPort = true
                    loadWithOverviewMode = true
                }

                webView.webChromeClient = WebChromeClient()
                webView.webViewClient = object : WebViewClient() {
                    override fun shouldOverrideUrlLoading(
                        view: WebView?,
                        request: WebResourceRequest?,
                    ): Boolean {
                        val target = request?.url?.toString() ?: return false
                        if (!target.startsWith("http://") && !target.startsWith("https://")) {
                            return true
                        }
                        finalLoadedUrl = target
                        return false
                    }

                    override fun shouldInterceptRequest(
                        view: WebView?,
                        request: WebResourceRequest?,
                    ): WebResourceResponse? {
                        val reqUrl = request?.url?.toString() ?: return null
                        inspectNetworkUrl(reqUrl, platform, capturedVideos, capturedImages)
                        return super.shouldInterceptRequest(view, request)
                    }

                    override fun onPageFinished(view: WebView?, loadedUrl: String?) {
                        super.onPageFinished(view, loadedUrl)
                        if (!loadedUrl.isNullOrBlank() && loadedUrl.startsWith("http")) {
                            finalLoadedUrl = loadedUrl
                        }
                        pageLoaded = true
                    }
                }

                val startTime = System.currentTimeMillis()
                var stableImagePolls = 0

                val poller = object : Runnable {
                    override fun run() {
                        if (finished.get()) return
                        val elapsed = System.currentTimeMillis() - startTime

                        if (elapsed >= timeoutMs) {
                            completeNow()
                            return
                        }

                        if (!pageLoaded && elapsed < 3000L) {
                            mainHandler.postDelayed(this, 600L)
                            return
                        }

                        webView.evaluateJavascript(buildDomExtractionJs()) { rawJs ->
                            if (finished.get()) return@evaluateJavascript
                            runCatching {
                                if (!rawJs.isNullOrBlank() && rawJs != "null") {
                                    val unquoted = if (rawJs.startsWith("\"") && rawJs.endsWith("\"")) {
                                        JSONObject("{\"v\":$rawJs}").getString("v")
                                    } else {
                                        rawJs
                                    }
                                    val json = JSONObject(unquoted)
                                    val t = json.optString("title", "").trim()
                                    if (t.isNotEmpty()) pageTitle = t
                                    val a = json.optString("author", "").trim()
                                    if (a.isNotEmpty()) pageAuthor = a
                                    val th = json.optString("thumbnail", "").trim()
                                    if (th.startsWith("http")) pageThumb = th

                                    val domVideos = json.optJSONArray("videos")
                                    if (domVideos != null) {
                                        for (i in 0 until domVideos.length()) {
                                            val v = domVideos.optString(i, "").trim()
                                            if (v.startsWith("http") && !v.startsWith("blob:")) {
                                                capturedVideos.add(normalizeVideoUrl(v, platform))
                                            }
                                        }
                                    }

                                    if (!isStrictVideoUrl) {
                                        val domImages = json.optJSONArray("images")
                                        if (domImages != null) {
                                            for (i in 0 until domImages.length()) {
                                                val img = domImages.optString(i, "").trim()
                                                if (isValidMediaImage(img, platform)) {
                                                    capturedImages.add(img)
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            val hasVideos = synchronized(capturedVideos) { capturedVideos.isNotEmpty() }
                            val hasImages = synchronized(capturedImages) { capturedImages.isNotEmpty() }

                            if (hasVideos && elapsed >= 1800L) {
                                completeNow()
                            } else if (!isStrictVideoUrl && hasImages && elapsed >= 5000L) {
                                stableImagePolls++
                                if (stableImagePolls >= 2) {
                                    completeNow()
                                } else {
                                    mainHandler.postDelayed(this, 800L)
                                }
                            } else {
                                mainHandler.postDelayed(this, 800L)
                            }
                        }
                    }
                }

                webView.loadUrl(url)
                mainHandler.postDelayed(poller, 1200L)
            } catch (t: Throwable) {
                Log.e(TAG, "sniffMedia crashed", t)
                cleanup()
                if (finished.compareAndSet(false, true)) {
                    onError("WEBVIEW_ERROR", t.message ?: "Gagal memuat halaman media")
                }
            }
        }
    }

    /**
     * Loads a social media profile (TikTok, Instagram, X, Facebook) in Android Chromium WebView,
     * scrolls down to collect ALL video/reel/post links from rendered DOM + hydration JSON
     * (and TikTok's own `itemList` network hydration), without any artificial count limit.
     */
    @SuppressLint("SetJavaScriptEnabled")
    fun sniffProfileItems(
        activity: Activity,
        url: String,
        platform: String,
        timeoutMs: Long = 28000L,
        onResult: (Map<String, Any?>) -> Unit,
        onError: (String, String) -> Unit,
    ) {
        mainHandler.post {
            val finished = AtomicBoolean(false)
            val collectedById = Collections.synchronizedMap(LinkedHashMap<String, Map<String, Any?>>())
            var finalLoadedUrl = url
            var creatorName = ""
            var pageLoaded = false

            val desktopUa =
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
            val userAgent = if (platform.equals("tiktok", ignoreCase = true)) desktopUa else MOBILE_ANDROID_UA

            val rootContainer = activity.window?.decorView as? ViewGroup
            val webView = try {
                WebView(activity)
            } catch (t: Throwable) {
                onError("WEBVIEW_ERROR", "WebView tidak tersedia: ${t.message}")
                return@post
            }

            val holder = FrameLayout(activity).apply {
                alpha = 0f
                isClickable = false
                isFocusable = false
                addView(webView, FrameLayout.LayoutParams(1280, 2200))
            }
            rootContainer?.addView(holder, ViewGroup.LayoutParams(1, 1))

            fun cleanup() {
                mainHandler.post {
                    runCatching {
                        webView.stopLoading()
                        webView.webViewClient = WebViewClient()
                        webView.webChromeClient = null
                        webView.loadUrl("about:blank")
                        rootContainer?.removeView(holder)
                        webView.destroy()
                    }
                }
            }

            fun completeNow() {
                if (!finished.compareAndSet(false, true)) return
                runCatching {
                    CookieManager.getInstance().flush()
                    exportAllCookiesToNetscapeFile()
                }
                val itemsList = synchronized(collectedById) { collectedById.values.toList() }
                cleanup()
                if (itemsList.isEmpty()) {
                    onError(
                        "PROFILE_SNIFF_EMPTY",
                        "Tidak menemukan daftar video/reel dari profil $platform. Coba Login Browser $platform di Pengaturan lalu ulangi.",
                    )
                } else {
                    onResult(
                        mapOf(
                            "finalUrl" to finalLoadedUrl,
                            "creator" to creatorName,
                            "items" to itemsList,
                        ),
                    )
                }
            }

            try {
                val cm = CookieManager.getInstance()
                cm.setAcceptCookie(true)
                cm.setAcceptThirdPartyCookies(webView, true)

                webView.settings.apply {
                    javaScriptEnabled = true
                    domStorageEnabled = true
                    databaseEnabled = true
                    loadsImagesAutomatically = false
                    mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
                    userAgentString = userAgent
                    cacheMode = WebSettings.LOAD_DEFAULT
                    useWideViewPort = true
                    loadWithOverviewMode = true
                }

                webView.webChromeClient = WebChromeClient()
                webView.webViewClient = object : WebViewClient() {
                    override fun shouldOverrideUrlLoading(
                        view: WebView?,
                        request: WebResourceRequest?,
                    ): Boolean {
                        val target = request?.url?.toString() ?: return false
                        if (!target.startsWith("http://") && !target.startsWith("https://")) return true
                        finalLoadedUrl = target
                        return false
                    }

                    override fun onPageFinished(view: WebView?, loadedUrl: String?) {
                        super.onPageFinished(view, loadedUrl)
                        if (!loadedUrl.isNullOrBlank() && loadedUrl.startsWith("http")) {
                            finalLoadedUrl = loadedUrl
                        }
                        pageLoaded = true
                    }
                }

                val startTime = System.currentTimeMillis()
                var lastCount = 0
                var stalePolls = 0

                val poller = object : Runnable {
                    override fun run() {
                        if (finished.get()) return
                        val elapsed = System.currentTimeMillis() - startTime
                        if (elapsed >= timeoutMs) {
                            completeNow()
                            return
                        }
                        if (!pageLoaded && elapsed < 3500L) {
                            mainHandler.postDelayed(this, 700L)
                            return
                        }

                        webView.evaluateJavascript(buildProfileExtractionJs(platform)) { rawJs ->
                            if (finished.get()) return@evaluateJavascript
                            runCatching {
                                if (!rawJs.isNullOrBlank() && rawJs != "null") {
                                    val unquoted = if (rawJs.startsWith("\"") && rawJs.endsWith("\"")) {
                                        JSONObject("{\"v\":$rawJs}").getString("v")
                                    } else {
                                        rawJs
                                    }
                                    val json = JSONObject(unquoted)
                                    val c = json.optString("creator", "").trim()
                                    if (c.isNotEmpty() && creatorName.isEmpty()) creatorName = c

                                    val arr = json.optJSONArray("items")
                                    if (arr != null) {
                                        for (i in 0 until arr.length()) {
                                            val obj = arr.optJSONObject(i) ?: continue
                                            val id = obj.optString("id", "").trim()
                                            val itemUrl = obj.optString("url", "").trim()
                                            if (id.isEmpty() || !itemUrl.startsWith("http")) continue
                                            val entry = mapOf(
                                                "id" to id,
                                                "url" to itemUrl,
                                                "title" to obj.optString("title", "").trim(),
                                                "thumbnail" to obj.optString("thumbnail", "").trim(),
                                                "badge" to obj.optString("badge", "").trim(),
                                                "kind" to obj.optString("kind", "video").trim(),
                                                "author" to obj.optString("author", creatorName).trim(),
                                            )
                                            synchronized(collectedById) {
                                                val prev = collectedById[id]
                                                if (prev == null || (prev["thumbnail"]?.toString().isNullOrEmpty() && entry["thumbnail"].toString().isNotEmpty())) {
                                                    collectedById[id] = entry
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            val currentCount = synchronized(collectedById) { collectedById.size }
                            if (currentCount > lastCount) {
                                lastCount = currentCount
                                stalePolls = 0
                            } else if (currentCount > 0) {
                                stalePolls++
                            }

                            // Stop once scrolling yields no more new items for 4 consecutive cycles (~4.8s)
                            if (currentCount > 0 && stalePolls >= 4) {
                                completeNow()
                            } else {
                                // Smoothly scroll down to trigger lazy-loading of remaining reels/posts
                                webView.evaluateJavascript(
                                    "window.scrollBy(0, Math.max(window.innerHeight * 2, 1600));",
                                    null,
                                )
                                mainHandler.postDelayed(this, 1200L)
                            }
                        }
                    }
                }

                webView.loadUrl(url)
                mainHandler.postDelayed(poller, 1800L)
            } catch (t: Throwable) {
                Log.e(TAG, "sniffProfileItems crashed", t)
                cleanup()
                if (finished.compareAndSet(false, true)) {
                    onError("WEBVIEW_ERROR", t.message ?: "Gagal memuat profil")
                }
            }
        }
    }

    private fun buildProfileExtractionJs(platform: String): String {
        val platLower = platform.lowercase()
        return """
        (function() {
          try {
            var platform = '$platLower';
            var creator = '';
            var byId = {};

            function addItem(id, url, title, thumb, badge, kind, author) {
              if (!id || !url) return;
              if (!byId[id] || (!byId[id].thumbnail && thumb)) {
                byId[id] = {
                  id: String(id),
                  url: String(url),
                  title: String(title || ''),
                  thumbnail: String(thumb || ''),
                  badge: String(badge || ''),
                  kind: String(kind || 'video'),
                  author: String(author || creator || '')
                };
              }
            }

            if (platform === 'tiktok') {
              var pathMatch = location.pathname.match(/\/@([^\/?#]+)/);
              if (pathMatch && pathMatch[1]) creator = pathMatch[1];

              // 1. Parse TikTok hydration script (__UNIVERSAL_DATA_FOR_REHYDRATION__ / SIGI_STATE)
              try {
                var el = document.getElementById('__UNIVERSAL_DATA_FOR_REHYDRATION__') || document.getElementById('SIGI_STATE');
                if (el && el.textContent) {
                  var data = JSON.parse(el.textContent);
                  function scanTk(node, depth) {
                    if (!node || depth > 10) return;
                    if (Array.isArray(node)) {
                      for (var i = 0; i < node.length; i++) scanTk(node[i], depth + 1);
                      return;
                    }
                    if (typeof node !== 'object') return;
                    if (node.id && (node.video || node.imagePost) && (node.desc !== undefined || node.author)) {
                      var uid = (node.author && (node.author.uniqueId || node.author.nickname)) || creator || 'tiktok';
                      if (!creator && uid) creator = uid;
                      var isPhoto = !!node.imagePost;
                      var itemUrl = 'https://www.tiktok.com/@' + uid + (isPhoto ? '/photo/' : '/video/') + node.id;
                      var thumb = (node.video && (node.video.cover || node.video.originCover || node.video.dynamicCover)) || '';
                      var dur = (node.video && node.video.duration) ? (node.video.duration + 's') : (isPhoto ? 'Foto' : 'Video');
                      addItem(node.id, itemUrl, node.desc || ('TikTok_' + node.id), thumb, dur, isPhoto ? 'image' : 'video', uid);
                    }
                    var ks = Object.keys(node);
                    for (var k = 0; k < ks.length; k++) {
                      var c = node[ks[k]];
                      if (c && typeof c === 'object') scanTk(c, depth + 1);
                    }
                  }
                  scanTk(data, 0);
                }
              } catch (e) {}

              // 2. Scan rendered DOM anchors for ALL loaded reels/videos/photos
              var anchors = document.querySelectorAll('a[href*="/video/"], a[href*="/photo/"]');
              for (var i = 0; i < anchors.length; i++) {
                var a = anchors[i];
                var href = a.href || '';
                var m = href.match(/\/@([^\/?#]+)\/(video|photo)\/(\d+)/);
                if (!m) continue;
                var u = m[1];
                var kindStr = m[2];
                var vidId = m[3];
                if (!creator) creator = u;
                var img = a.querySelector('img');
                var thumb = (img && (img.currentSrc || img.src)) || '';
                var alt = (img && img.alt) || a.getAttribute('title') || a.innerText || ('TikTok_' + vidId);
                alt = alt.replace(/\s+/g, ' ').trim();
                var cleanHref = 'https://www.tiktok.com/@' + u + '/' + kindStr + '/' + vidId;
                addItem(vidId, cleanHref, alt, thumb, kindStr === 'photo' ? 'Foto' : 'Video', kindStr === 'photo' ? 'image' : 'video', u);
              }
            } else if (platform === 'instagram') {
              var igMatch = location.pathname.match(/^\/([^\/?#]+)/);
              if (igMatch && igMatch[1]) creator = igMatch[1];
              var igLinks = document.querySelectorAll('a[href*="/reel/"], a[href*="/p/"]');
              for (var j = 0; j < igLinks.length; j++) {
                var la = igLinks[j];
                var hm = (la.href || '').match(/\/(reel|p)\/([A-Za-z0-9_-]{5,30})/);
                if (!hm) continue;
                var code = hm[2];
                var im = la.querySelector('img');
                var th = (im && (im.currentSrc || im.src)) || '';
                var tit = (im && im.alt) || ('Instagram_' + code);
                addItem(code, 'https://www.instagram.com/' + hm[1] + '/' + code + '/', tit, th, hm[1] === 'reel' ? 'Reel' : 'Post', 'video', creator);
              }
            } else if (platform === 'x') {
              var xLinks = document.querySelectorAll('a[href*="/status/"]');
              for (var x = 0; x < xLinks.length; x++) {
                var xa = xLinks[x];
                var xm = (xa.href || '').match(/\/([^\/?#]+)\/status\/(\d+)/);
                if (!xm) continue;
                if (!creator) creator = xm[1];
                var xid = xm[2];
                addItem(xid, 'https://x.com/' + xm[1] + '/status/' + xid, 'Post X ' + xid, '', 'Post', 'video', xm[1]);
              }
            }

            var out = [];
            var ids = Object.keys(byId);
            for (var n = 0; n < ids.length; n++) out.push(byId[ids[n]]);
            return JSON.stringify({ creator: creator, items: out });
          } catch (err) {
            return JSON.stringify({ creator: '', items: [] });
          }
        })();
        """.trimIndent()
    }

    @SuppressLint("SetJavaScriptEnabled")
    fun openLoginDialog(
        activity: Activity,
        platform: String,
        onDone: (Map<String, Any?>) -> Unit,
    ) {
        mainHandler.post {
            val targetUrl = when (platform.lowercase()) {
                "douyin" -> "https://www.douyin.com/"
                "tiktok" -> "https://www.tiktok.com/login"
                "facebook" -> "https://m.facebook.com/login/"
                "pixiv" -> "https://accounts.pixiv.net/login"
                else -> "https://www.instagram.com/accounts/login/"
            }
            val label = when (platform.lowercase()) {
                "douyin" -> "Login Douyin"
                "tiktok" -> "Login TikTok"
                "facebook" -> "Login Facebook"
                "pixiv" -> "Login Pixiv (R-18 & Member)"
                else -> "Login Instagram"
            }

            val dialog = Dialog(activity, android.R.style.Theme_DeviceDefault_NoActionBar_Fullscreen)
            val webView = WebView(activity)

            val cookieManager = CookieManager.getInstance()
            cookieManager.setAcceptCookie(true)
            cookieManager.setAcceptThirdPartyCookies(webView, true)

            webView.settings.apply {
                javaScriptEnabled = true
                domStorageEnabled = true
                databaseEnabled = true
                userAgentString = MOBILE_ANDROID_UA
                mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
            }
            webView.webChromeClient = WebChromeClient()
            webView.webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(
                    view: WebView?,
                    request: WebResourceRequest?,
                ): Boolean {
                    val u = request?.url?.toString() ?: return false
                    return !u.startsWith("http://") && !u.startsWith("https://")
                }
            }

            val root = LinearLayout(activity).apply {
                orientation = LinearLayout.VERTICAL
                setBackgroundColor(Color.parseColor("#090D16"))
            }

            val topBar = LinearLayout(activity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(32, 28, 24, 24)
                setBackgroundColor(Color.parseColor("#111827"))
            }

            val titleView = TextView(activity).apply {
                text = "$label (Opsional)"
                setTextColor(Color.WHITE)
                textSize = 16f
                layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
            }

            val doneBtn = Button(activity).apply {
                text = "Selesai & Simpan"
                setTextColor(Color.WHITE)
                setBackgroundColor(Color.parseColor("#0284C7"))
                setOnClickListener {
                    runCatching { CookieManager.getInstance().flush() }
                    val cookieFile = exportAllCookiesToNetscapeFile()
                    val hasCookies = hasPlatformCookies(platform)
                    runCatching {
                        webView.stopLoading()
                        webView.destroy()
                    }
                    dialog.dismiss()
                    onDone(
                        mapOf(
                            "saved" to hasCookies,
                            "cookiesPath" to (cookieFile?.absolutePath ?: ""),
                        ),
                    )
                }
            }

            topBar.addView(titleView)
            topBar.addView(doneBtn)
            root.addView(topBar, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            root.addView(webView, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))

            dialog.setContentView(root)
            dialog.setOnCancelListener {
                runCatching { CookieManager.getInstance().flush() }
                val cookieFile = exportAllCookiesToNetscapeFile()
                val hasCookies = hasPlatformCookies(platform)
                runCatching {
                    webView.stopLoading()
                    webView.destroy()
                }
                onDone(
                    mapOf(
                        "saved" to hasCookies,
                        "cookiesPath" to (cookieFile?.absolutePath ?: ""),
                    ),
                )
            }

            dialog.show()
            webView.loadUrl(targetUrl)
        }
    }

    fun hasPlatformCookies(platform: String): Boolean {
        val cm = CookieManager.getInstance()
        return when (platform.lowercase()) {
            "instagram" -> cm.getCookie("https://www.instagram.com").orEmpty().contains("sessionid=")
            "douyin" -> {
                val c = cm.getCookie("https://www.douyin.com").orEmpty() +
                    cm.getCookie("https://www.iesdouyin.com").orEmpty()
                c.contains("ttwid=") || c.contains("sessionid=") || c.contains("odin_tt=")
            }
            "facebook" -> cm.getCookie("https://www.facebook.com").orEmpty().contains("c_user=") ||
                cm.getCookie("https://m.facebook.com").orEmpty().contains("c_user=")
            "pixiv" -> {
                val c = cm.getCookie("https://www.pixiv.net").orEmpty() + "; " +
                    cm.getCookie("https://pixiv.net").orEmpty()
                c.contains("PHPSESSID=")
            }
            "tiktok" -> {
                val c = cm.getCookie("https://www.tiktok.com").orEmpty()
                c.contains("sessionid=") || c.contains("sid_tt=") || c.contains("tt_chain_token=")
            }
            else -> false
        }
    }

    fun getCookieHeaderForUrl(url: String): String {
        return runCatching {
            val cm = CookieManager.getInstance()
            if (url.contains("pixiv.net", ignoreCase = true)) {
                val merged = LinkedHashMap<String, String>()
                val sources = listOf(
                    "https://accounts.pixiv.net",
                    "https://pixiv.net",
                    "https://www.pixiv.net",
                    url,
                )
                for (src in sources) {
                    val raw = cm.getCookie(src).orEmpty()
                    if (raw.isBlank()) continue
                    for (pair in raw.split(";")) {
                        val eq = pair.indexOf('=')
                        if (eq <= 0) continue
                        val k = pair.substring(0, eq).trim()
                        val v = pair.substring(eq + 1).trim()
                        if (k.isNotEmpty()) merged[k] = v
                    }
                }
                merged.entries.joinToString("; ") { "${it.key}=${it.value}" }
            } else {
                cm.getCookie(url).orEmpty()
            }
        }.getOrDefault("")
    }

    fun clearWebViewCookies(onDone: () -> Unit) {
        mainHandler.post {
            CookieManager.getInstance().removeAllCookies {
                CookieManager.getInstance().flush()
                runCatching { File(context.filesDir, "webview_cookies.txt").delete() }
                onDone()
            }
        }
    }

    fun exportAllCookiesToNetscapeFile(): File? {
        return runCatching {
            val cm = CookieManager.getInstance()
            val domainMap = listOf(
                ".instagram.com" to "https://www.instagram.com",
                ".douyin.com" to "https://www.douyin.com",
                ".iesdouyin.com" to "https://www.iesdouyin.com",
                ".tiktok.com" to "https://www.tiktok.com",
                ".youtube.com" to "https://www.youtube.com",
                ".x.com" to "https://x.com",
                ".facebook.com" to "https://www.facebook.com",
                ".pixiv.net" to "https://www.pixiv.net",
            )
            val lines = mutableListOf("# Netscape HTTP Cookie File")
            val seen = HashSet<String>()
            val expiry = (System.currentTimeMillis() / 1000L) + 86400L * 180L

            for ((domain, url) in domainMap) {
                val raw = cm.getCookie(url).orEmpty()
                if (raw.isBlank()) continue
                for (pair in raw.split(";")) {
                    val idx = pair.indexOf('=')
                    if (idx <= 0) continue
                    val name = pair.substring(0, idx).trim()
                    val value = pair.substring(idx + 1).trim()
                    if (name.isEmpty()) continue
                    val key = "$domain|$name"
                    if (seen.add(key)) {
                        lines.add("$domain\tTRUE\t/\tTRUE\t$expiry\t$name\t$value")
                    }
                }
            }

            if (lines.size <= 1) return@runCatching null
            val outFile = File(context.filesDir, "webview_cookies.txt")
            outFile.writeText(lines.joinToString("\n"))
            outFile
        }.getOrNull()
    }

    private fun collectCookieHeader(finalUrl: String, originalUrl: String, platform: String): String {
        val cm = CookieManager.getInstance()
        val parts = LinkedHashSet<String>()
        val urls = mutableListOf(finalUrl, originalUrl)
        when (platform.lowercase()) {
            "douyin" -> {
                urls.add("https://www.douyin.com")
                urls.add("https://www.iesdouyin.com")
                urls.add("https://aweme.snssdk.com")
            }
            "instagram" -> urls.add("https://www.instagram.com")
            "facebook" -> {
                urls.add("https://www.facebook.com")
                urls.add("https://m.facebook.com")
            }
            "pixiv" -> urls.add("https://www.pixiv.net")
        }
        for (u in urls) {
            val c = cm.getCookie(u).orEmpty().trim()
            if (c.isNotEmpty()) {
                c.split(";").map { it.trim() }.filter { it.contains("=") }.forEach { parts.add(it) }
            }
        }
        return parts.joinToString("; ")
    }

    private fun inspectNetworkUrl(
        rawUrl: String,
        platform: String,
        videos: MutableSet<String>,
        images: MutableSet<String>,
    ) {
        val lower = rawUrl.lowercase()
        if (!lower.startsWith("http://") && !lower.startsWith("https://")) return

        if (platform.equals("douyin", ignoreCase = true)) {
            val isDouyinVideo = (lower.contains("douyinvod.com") ||
                lower.contains("aweme.snssdk.com/aweme/v1/play") ||
                lower.contains("snssdk.com/aweme/v1/play") ||
                (lower.contains("zjcdn.com") && lower.contains("video")) ||
                (lower.contains("bytegoofy.com") && lower.contains(".mp4")) ||
                (lower.contains("amemv.com") && lower.contains("play")) ||
                (lower.contains(".mp4") && !lower.contains("static"))) &&
                !lower.contains(".js") && !lower.contains(".css")
            if (isDouyinVideo) {
                videos.add(normalizeVideoUrl(rawUrl, platform))
                return
            }
            if ((lower.contains("douyinpic.com") || lower.contains("byteimg.com")) &&
                !lower.contains("avatar") && !lower.contains("100x100") &&
                !lower.contains("tos-cn-i-0813c001") &&
                (lower.contains("tplv-dy") || lower.contains("noop") || lower.contains(".jpeg") || lower.contains(".jpg"))
            ) {
                images.add(rawUrl.replaceFirst("http://", "https://"))
            }
        } else if (platform.equals("instagram", ignoreCase = true) ||
            platform.equals("facebook", ignoreCase = true)
        ) {
            val isMetaHost = lower.contains("cdninstagram.com") || lower.contains("fbcdn.net")
            if (!isMetaHost || lower.contains("/rsrc.php/") || lower.contains("static.")) return

            // Skip tiny DASH audio-only segments if identifiable, keep progressive MP4 streams
            if ((lower.contains(".mp4") || lower.contains("mime_type=video") ||
                    lower.contains("/v/t50.") || lower.contains("/o1/v/t16/")) &&
                !lower.contains("bytestart=")
            ) {
                videos.add(stripRangeParams(rawUrl))
                return
            }

            if (isValidMediaImage(rawUrl, platform)) {
                images.add(rawUrl)
            }
        }
    }

    private fun normalizeVideoUrl(url: String, platform: String): String {
        var clean = url.replaceFirst("http://", "https://")
        if (platform.equals("douyin", ignoreCase = true)) {
            clean = clean.replace("playwm", "play")
        }
        return clean
    }

    private fun stripRangeParams(rawUrl: String): String {
        return runCatching {
            val uri = Uri.parse(rawUrl)
            if (uri.getQueryParameter("bytestart") == null && uri.getQueryParameter("byteend") == null) {
                return@runCatching rawUrl
            }
            val builder = uri.buildUpon().clearQuery()
            for (name in uri.queryParameterNames) {
                if (name != "bytestart" && name != "byteend") {
                    uri.getQueryParameters(name).forEach { v ->
                        builder.appendQueryParameter(name, v)
                    }
                }
            }
            builder.build().toString()
        }.getOrDefault(rawUrl)
    }

    private fun isValidMediaImage(url: String, platform: String): Boolean {
        val lower = url.lowercase()
        if (!lower.startsWith("http")) return false
        if (lower.contains("/rsrc.php/") || lower.contains("static.") || lower.contains(".svg") ||
            lower.contains("favicon") || lower.contains("logo") || lower.contains("avatar") ||
            lower.contains("150x150") || lower.contains("s150x150") || lower.contains("p150x150") ||
            lower.contains("100x100") || lower.contains("emoji") || lower.contains("sprite") ||
            lower.contains("profile_pic")
        ) {
            return false
        }
        if (platform.equals("instagram", ignoreCase = true) ||
            platform.equals("facebook", ignoreCase = true)
        ) {
            return (lower.contains("cdninstagram.com") || lower.contains("fbcdn.net")) &&
                (lower.contains("t51.2885-15") || lower.contains("t51.29350-15") ||
                    lower.contains("scontent") || lower.contains(".jpg") || lower.contains(".webp"))
        }
        if (platform.equals("douyin", ignoreCase = true)) {
            return lower.contains("douyinpic.com") || lower.contains("byteimg.com")
        }
        return true
    }

    /**
     * Extracts direct media URLs from rendered DOM + embedded `<script type="application/json">`
     * (crucial for Instagram Reels where `<video src>` is an MSE `blob:` URL, while the real
     * progressive MP4 lives inside Instagram's embedded `video_versions` JSON!).
     */
    private fun buildDomExtractionJs(): String {
        return """
        (function() {
          try {
            var videos = [];
            var images = [];
            var title = '';
            var author = '';
            var thumbnail = '';

            var ogTitle = document.querySelector('meta[property="og:title"]');
            var ogDesc = document.querySelector('meta[property="og:description"]');
            var ogVideo = document.querySelector('meta[property="og:video"], meta[property="og:video:secure_url"]');
            var ogImage = document.querySelector('meta[property="og:image"]');

            if (ogDesc && ogDesc.content) title = ogDesc.content;
            if (!title && ogTitle && ogTitle.content) title = ogTitle.content;
            if (!title && document.title) title = document.title;
            if (ogImage && ogImage.content) thumbnail = ogImage.content;
            if (ogVideo && ogVideo.content && ogVideo.content.indexOf('http') === 0) {
              videos.push(ogVideo.content);
            }

            // 1. Inspect <video> elements (ignoring blob: MSE placeholders)
            var vEls = document.querySelectorAll('video');
            for (var i = 0; i < vEls.length; i++) {
              var v = vEls[i];
              if (v.currentSrc && v.currentSrc.indexOf('http') === 0) videos.push(v.currentSrc);
              if (v.src && v.src.indexOf('http') === 0) videos.push(v.src);
              if (v.poster && v.poster.indexOf('http') === 0 && !thumbnail) thumbnail = v.poster;
              var sources = v.querySelectorAll('source');
              for (var j = 0; j < sources.length; j++) {
                if (sources[j].src && sources[j].src.indexOf('http') === 0) videos.push(sources[j].src);
              }
            }

            // 2. Scan embedded JSON script blocks (Instagram Reels video_versions / carousel_media / Facebook playable_url)
            function walkJson(node, depth) {
              if (!node || depth > 14) return;
              if (Array.isArray(node)) {
                for (var idx = 0; idx < node.length; idx++) {
                  walkJson(node[idx], depth + 1);
                }
                return;
              }
              if (typeof node !== 'object') return;

              // Instagram / Facebook video_versions array (pick highest resolution)
              if (Array.isArray(node.video_versions) && node.video_versions.length > 0) {
                var best = node.video_versions[0];
                for (var vi = 1; vi < node.video_versions.length; vi++) {
                  var cand = node.video_versions[vi];
                  if (cand && cand.url && ((cand.width || 0) > (best.width || 0))) {
                    best = cand;
                  }
                }
                if (best && best.url && best.url.indexOf('http') === 0) {
                  videos.push(best.url);
                }
              }

              // Direct video_url / playable_url_quality_hd / playable_url
              var vKeys = ['video_url', 'playable_url_quality_hd', 'playable_url', 'browser_native_hd_url', 'browser_native_sd_url'];
              for (var vk = 0; vk < vKeys.length; vk++) {
                var val = node[vKeys[vk]];
                if (typeof val === 'string' && val.indexOf('http') === 0) {
                  videos.push(val);
                }
              }

              // Author / username
              if (!author && node.user && typeof node.user.username === 'string' && node.user.username) {
                author = node.user.username;
              }
              if (!author && node.owner && typeof node.owner.username === 'string' && node.owner.username) {
                author = node.owner.username;
              }
              if (!title && node.caption && typeof node.caption.text === 'string' && node.caption.text) {
                title = node.caption.text;
              }

              // Instagram carousel_media photos & videos
              if (Array.isArray(node.carousel_media) && node.carousel_media.length > 0) {
                for (var ci = 0; ci < node.carousel_media.length; ci++) {
                  var item = node.carousel_media[ci];
                  if (item && Array.isArray(item.video_versions) && item.video_versions.length > 0 && item.video_versions[0].url) {
                    videos.push(item.video_versions[0].url);
                  } else if (item && item.image_versions2 && Array.isArray(item.image_versions2.candidates) && item.image_versions2.candidates.length > 0) {
                    images.push(item.image_versions2.candidates[0].url);
                  }
                }
              }

              // Single post image_versions2 thumbnail/photo
              if (node.image_versions2 && Array.isArray(node.image_versions2.candidates) && node.image_versions2.candidates.length > 0) {
                var imgUrl = node.image_versions2.candidates[0].url;
                if (imgUrl && imgUrl.indexOf('http') === 0) {
                  if (!thumbnail) thumbnail = imgUrl;
                  if (!node.video_versions) images.push(imgUrl);
                }
              }

              var keys = Object.keys(node);
              for (var k = 0; k < keys.length; k++) {
                var key = keys[k];
                if (key === 'extensions' || key === 'styles' || key === 'rsrcMap') continue;
                var child = node[key];
                if (child && typeof child === 'object') {
                  walkJson(child, depth + 1);
                }
              }
            }

            var scripts = document.querySelectorAll('script[type="application/json"]');
            for (var s = 0; s < scripts.length; s++) {
              var txt = scripts[s].textContent || '';
              if (txt.indexOf('video_versions') !== -1 || txt.indexOf('video_url') !== -1 ||
                  txt.indexOf('playable_url') !== -1 || txt.indexOf('carousel_media') !== -1 ||
                  txt.indexOf('xdt_shortcode_media') !== -1) {
                try {
                  walkJson(JSON.parse(txt), 0);
                } catch (e) {}
              }
            }

            // 3. Try Douyin _ROUTER_DATA if hydrated
            try {
              if (window._ROUTER_DATA && window._ROUTER_DATA.loaderData) {
                var ld = window._ROUTER_DATA.loaderData;
                for (var dk in ld) {
                  var page = ld[dk];
                  if (page && page.videoInfoRes && page.videoInfoRes.item_list && page.videoInfoRes.item_list.length > 0) {
                    var dItem = page.videoInfoRes.item_list[0];
                    if (dItem.desc) title = dItem.desc;
                    if (dItem.author && dItem.author.nickname) author = dItem.author.nickname;
                    if (dItem.video && dItem.video.play_addr && dItem.video.play_addr.url_list && dItem.video.play_addr.url_list.length > 0) {
                      videos.push(dItem.video.play_addr.url_list[0]);
                    }
                    if (dItem.video && dItem.video.cover && dItem.video.cover.url_list && dItem.video.cover.url_list.length > 0) {
                      thumbnail = dItem.video.cover.url_list[0];
                    }
                    if (dItem.images && dItem.images.length > 0) {
                      for (var dm = 0; dm < dItem.images.length; dm++) {
                        if (dItem.images[dm].url_list && dItem.images[dm].url_list.length > 0) {
                          images.push(dItem.images[dm].url_list[0]);
                        }
                      }
                    }
                  }
                }
              }
            } catch (e) {}

            // 4. Fallback large DOM images
            var imgEls = document.querySelectorAll('article img, main img, img');
            for (var n = 0; n < imgEls.length; n++) {
              var im = imgEls[n];
              var src = im.currentSrc || im.src || '';
              if (src.indexOf('http') === 0 && (im.naturalWidth >= 400 || im.width >= 300)) {
                images.push(src);
                if (!thumbnail) thumbnail = src;
              }
            }

            return JSON.stringify({
              title: title,
              author: author,
              thumbnail: thumbnail,
              videos: videos,
              images: images
            });
          } catch (err) {
            return JSON.stringify({ title: '', author: '', thumbnail: '', videos: [], images: [] });
          }
        })();
        """.trimIndent()
    }
}
