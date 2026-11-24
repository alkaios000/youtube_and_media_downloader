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
        timeoutMs: Long = 15000L,
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

            // Attach off-screen 1x1 so Chromium actually executes JS, video layout & network requests
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
                val images = synchronized(capturedImages) { capturedImages.toList() }
                cleanup()

                if (videos.isEmpty() && images.isEmpty()) {
                    onError(
                        "SNIFF_EMPTY",
                        "Tidak menemukan stream video/foto di halaman ini. Konten mungkin memerlukan login (coba Login Browser di Pengaturan).",
                    )
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
                        // Block custom app schemes (snssdk1128://, instagram://, intent://, etc.)
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

                // Periodic DOM inspection to grab <video>, <img>, og:tags, & Douyin _ROUTER_DATA
                val startTime = System.currentTimeMillis()
                var stableEmptyPolls = 0

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
                                    // evaluateJavascript wraps string return values in JSON quotes
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

                            val hasVideos = synchronized(capturedVideos) { capturedVideos.isNotEmpty() }
                            val hasImages = synchronized(capturedImages) { capturedImages.isNotEmpty() }

                            if (hasVideos && elapsed >= 1800L) {
                                // Video stream found and page metadata settled -> finish immediately!
                                completeNow()
                            } else if (hasImages && elapsed >= 4500L) {
                                // Give video 4.5s to load first; if only images exist, return photo post!
                                stableEmptyPolls++
                                if (stableEmptyPolls >= 2) {
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
                else -> "https://www.instagram.com/accounts/login/"
            }
            val label = when (platform.lowercase()) {
                "douyin" -> "Login Douyin"
                "tiktok" -> "Login TikTok"
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
            "instagram" -> {
                val c = cm.getCookie("https://www.instagram.com").orEmpty()
                c.contains("sessionid=")
            }
            "douyin" -> {
                val c = cm.getCookie("https://www.douyin.com").orEmpty() +
                    cm.getCookie("https://www.iesdouyin.com").orEmpty()
                c.contains("ttwid=") || c.contains("sessionid=") || c.contains("odin_tt=")
            }
            else -> false
        }
    }

    fun getWebViewCookiesFilePath(): String? {
        val file = exportAllCookiesToNetscapeFile()
        return if (file != null && file.exists() && file.length() > 30) file.absolutePath else null
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
        if (platform.equals("douyin", ignoreCase = true)) {
            urls.add("https://www.douyin.com")
            urls.add("https://www.iesdouyin.com")
            urls.add("https://aweme.snssdk.com")
        } else if (platform.equals("instagram", ignoreCase = true)) {
            urls.add("https://www.instagram.com")
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
                lower.contains("zjcdn.com") && lower.contains("video") ||
                lower.contains("bytegoofy.com") && lower.contains(".mp4") ||
                lower.contains("amemv.com") && lower.contains("play") ||
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
        } else if (platform.equals("instagram", ignoreCase = true)) {
            val isIgHost = lower.contains("cdninstagram.com") || lower.contains("fbcdn.net")
            if (!isIgHost || lower.contains("/rsrc.php/") || lower.contains("static.")) return

            if (lower.contains(".mp4") || lower.contains("mime_type=video") || lower.contains("/v/t50.") || lower.contains("/o1/v/t16/")) {
                // Strip byte-range query params if Instagram requested a chunked DASH segment
                val cleaned = stripRangeParams(rawUrl)
                if (!lower.contains("bytestart=") || !videos.any { it == cleaned }) {
                    videos.add(cleaned)
                }
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
            lower.contains("100x100") || lower.contains("emoji") || lower.contains("sprite")
        ) {
            return false
        }
        if (platform.equals("instagram", ignoreCase = true)) {
            return (lower.contains("cdninstagram.com") || lower.contains("fbcdn.net")) &&
                (lower.contains("t51.2885-15") || lower.contains("t51.29350-15") || lower.contains(".jpg") || lower.contains(".webp"))
        }
        if (platform.equals("douyin", ignoreCase = true)) {
            return lower.contains("douyinpic.com") || lower.contains("byteimg.com")
        }
        return true
    }

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

            // Extract <video> and <source> elements
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

            // Try Douyin _ROUTER_DATA if present after hydration
            try {
              if (window._ROUTER_DATA && window._ROUTER_DATA.loaderData) {
                var ld = window._ROUTER_DATA.loaderData;
                for (var k in ld) {
                  var page = ld[k];
                  if (page && page.videoInfoRes && page.videoInfoRes.item_list && page.videoInfoRes.item_list.length > 0) {
                    var item = page.videoInfoRes.item_list[0];
                    if (item.desc) title = item.desc;
                    if (item.author && item.author.nickname) author = item.author.nickname;
                    if (item.video && item.video.play_addr && item.video.play_addr.url_list && item.video.play_addr.url_list.length > 0) {
                      videos.push(item.video.play_addr.url_list[0]);
                    }
                    if (item.video && item.video.cover && item.video.cover.url_list && item.video.cover.url_list.length > 0) {
                      thumbnail = item.video.cover.url_list[0];
                    }
                    if (item.images && item.images.length > 0) {
                      for (var m = 0; m < item.images.length; m++) {
                        if (item.images[m].url_list && item.images[m].url_list.length > 0) {
                          images.push(item.images[m].url_list[0]);
                        }
                      }
                    }
                  }
                }
              }
            } catch (e) {}

            // Extract large content images (for Instagram posts & Douyin slides)
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
