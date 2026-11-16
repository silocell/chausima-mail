// Chausima Mail desktop: a window onto https://mail.chausima.com. Links to other sites open in the normal browser.
const { app, BrowserWindow, shell, Menu } = require("electron");
const path = require("path");
const HOME = "https://mail.chausima.com/";
function open() {
  const win = new BrowserWindow({
    width: 1280, height: 820, minWidth: 380, minHeight: 500, title: "Chausima Mail",
    icon: path.join(__dirname, "build", "icon.png"), backgroundColor: "#f3f5f7",
    webPreferences: { contextIsolation: true, sandbox: true, nodeIntegration: false }
  });
  win.loadURL(HOME);
  const outside = (url) => !url.startsWith(HOME);
  win.webContents.setWindowOpenHandler(({ url }) => { if (/^https?:/.test(url)) shell.openExternal(url); return { action: "deny" }; });
  win.webContents.on("will-navigate", (e, url) => { if (outside(url)) { e.preventDefault(); if (/^https?:/.test(url)) shell.openExternal(url); } });
  win.webContents.on("did-fail-load", () => win.loadURL("data:text/html,<body style='font:16px system-ui;padding:40px;color:%23333'><h2>Can%27t reach Chausima Mail</h2><p>Check your internet, then press Ctrl+R (Cmd+R on Mac) to try again.</p></body>"));
}
if (!app.requestSingleInstanceLock()) app.quit();
app.whenReady().then(() => { if (process.platform !== "darwin") Menu.setApplicationMenu(null); open(); });
app.on("window-all-closed", () => { if (process.platform !== "darwin") app.quit(); });
app.on("activate", () => { if (BrowserWindow.getAllWindows().length === 0) open(); });
