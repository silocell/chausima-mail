package com.chausima.mail;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

/** Chausima Mail for Android: a window onto https://mail.chausima.com. Other sites open in the normal browser. */
public class MainActivity extends Activity {
  private static final String HOME = "https://mail.chausima.com/";
  private WebView web;

  @Override protected void onCreate(Bundle state) {
    super.onCreate(state);
    getWindow().setStatusBarColor(Color.parseColor("#c8312b"));
    web = new WebView(this);
    WebSettings s = web.getSettings();
    s.setJavaScriptEnabled(true);
    s.setDomStorageEnabled(true);
    s.setAllowFileAccess(false);
    s.setAllowContentAccess(false);
    web.setWebViewClient(new WebViewClient() {
      @Override public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest r) {
        Uri u = r.getUrl();
        if (u.toString().startsWith(HOME)) return false;
        try { startActivity(new Intent(Intent.ACTION_VIEW, u)); } catch (Exception ignored) {}
        return true;
      }
      @Override public void onReceivedError(WebView v, WebResourceRequest r, WebResourceError e) {
        if (r.isForMainFrame()) v.loadData("<body style='font:16px sans-serif;padding:32px;color:#333'><h2>Can't reach Chausima Mail</h2><p>Check your internet, then pull down or reopen the app to try again.</p><p><a href='" + HOME + "'>Try again</a></p></body>", "text/html", "utf-8");
      }
    });
    setContentView(web);
    if (state != null) web.restoreState(state); else web.loadUrl(HOME);
  }
  @Override protected void onSaveInstanceState(Bundle out) { super.onSaveInstanceState(out); web.saveState(out); }
  @Override public void onBackPressed() { if (web.canGoBack()) web.goBack(); else super.onBackPressed(); }
}
