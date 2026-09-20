/*
 * 「清空环境」main.js 后端目录自动查找 —— 离线模拟测试
 * 用假的 UXP storage API（底层是真文件系统）把插件里的 detectComfyDir / pathExists / launchBat 跑一遍。
 */
const realfs = require("fs");
const realpath = require("path");
const os = require("os");
const vm = require("vm");

// 临时"假磁盘"放在系统临时目录里，不污染仓库
const BASE = realpath.join(os.tmpdir(), "cleanbg-detect-test");
const DRIVES = { "C:": realpath.join(BASE, "C"), "D:": realpath.join(BASE, "D"), "E:": realpath.join(BASE, "E") };

// 找 main.js：既支持"和测试脚本同目录"，也支持仓库布局（plugin/cleanbg/main.js）和源码目录
function findMainJs() {
  const cands = [
    realpath.join(__dirname, "main.js"),
    realpath.join(__dirname, "..", "plugin", "cleanbg", "main.js"),
    realpath.join(__dirname, "plugin", "cleanbg", "main.js"),
    realpath.join(__dirname, "..", "源文件", "main.js")
  ];
  for (const c of cands) { if (realfs.existsSync(c)) return c; }
  throw new Error("没找到 main.js，试过：" + cands.join(" | "));
}
const MAIN_JS = findMainJs();

function naturalFromUrl(url) {
  let u = String(url).replace(/^file:\/{2,}/i, "");
  u = decodeURI(u);
  const m = u.match(/^([A-Za-z]):[\/\\]?(.*)$/);
  if (!m) return null;
  const drv = m[1].toUpperCase() + ":";
  const base = DRIVES[drv];
  if (!base) return null;
  const rest = (m[2] || "").replace(/^[\/\\]+/, "");
  return rest ? realpath.join(base, rest) : base;
}

// 把假磁盘上的真实路径翻译回"假盘符路径"，让 nativePath/url 能和 UXP 一样来回换算
function fakeNative(p) {
  const rel = realpath.relative(BASE, p);
  if (rel.startsWith("..")) return p;
  const parts = rel.split(realpath.sep);
  if (parts.length < 1) return p;
  const drv = parts.shift();
  return (drv + ":\\" + parts.join("\\")).replace(/\\$/, "\\");
}

function mkEntry(p) {
  const st = realfs.statSync(p); // 不存在就抛，和 UXP 行为一致
  const isFolder = st.isDirectory();
  const nat = fakeNative(p);
  return {
    name: realpath.basename(p),
    nativePath: nat,
    url: "file:///" + nat.replace(/\\/g, "/"),
    isFolder,
    async getEntries() {
      return realfs.readdirSync(p).map((n) => mkEntry(realpath.join(p, n)));
    },
    async getEntry(n) {
      return mkEntry(realpath.join(p, n));
    },
    async getParent() {
      const par = realpath.dirname(p);
      if (par === p) return null;
      return mkEntry(par);
    },
    async createFile() { throw new Error("createFile 没实现（测试用不到）"); },
    async write() { throw new Error("write 没实现（测试用不到）"); }
  };
}

const launched = [];
const pluginFolder = { p: null };   // 设置后 getPluginFolder 返回它

const fakeLS = {
  async getPluginFolder() {
    if (!pluginFolder.p) throw new Error("拿不到插件目录（模拟）");
    return mkEntry(pluginFolder.p);
  },
  async getEntryWithUrl(url) {
    const p = naturalFromUrl(url);
    if (!p) throw new Error("unsupported url: " + url);
    return mkEntry(p);   // 不存在 → statSync 抛 → promise reject
  }
};

const shell = {
  async openPath(p) { launched.push(p); return ""; },
  async openExternal() { throw new Error("file scheme is not supported"); }
};

function fakeRequire(name) {
  if (name === "uxp") return { storage: { localFileSystem: fakeLS }, shell };
  if (name === "photoshop") {
    return {
      app: { activeDocument: null },
      core: { executeAsModal: async (fn) => fn() },
      action: { batchPlay: async () => { throw new Error("没有选区（模拟）"); } }
    };
  }
  throw new Error("未知模块: " + name);
}

const els = {};
function mkEl(id) {
  if (!els[id]) {
    els[id] = {
      id, textContent: "", value: "", disabled: false, checked: false,
      scrollTop: 0, scrollHeight: 0, style: {}, addEventListener() {}
    };
  }
  return els[id];
}

const store = {};
const sandbox = {
  require: fakeRequire,
  console,
  document: { getElementById: mkEl },
  localStorage: {
    getItem: (k) => (Object.prototype.hasOwnProperty.call(store, k) ? store[k] : null),
    setItem: (k, v) => { store[k] = String(v); },
    removeItem: (k) => { delete store[k]; }
  },
  fetch: async () => ({ ok: false }),
  AbortController: undefined
};

console.log("被测文件：" + MAIN_JS + "\n");
const code = realfs.readFileSync(MAIN_JS, "utf8") +
  "\nglobalThis.__T = { detectComfyDir, pathExists, isComfyDir, applyComfyDir, launchBat, ensureComfyDir, getDir: () => COMFY_DIR, reset: () => { dirReadyPromise = null; } };\n";

const ctx = vm.createContext(sandbox);
vm.runInContext(code, ctx, { filename: "main.js" });
const T = ctx.__T;

let pass = 0, fail = 0;
function check(name, cond, extra) {
  if (cond) { pass++; console.log("  [PASS] " + name); }
  else { fail++; console.log("  [FAIL] " + name + (extra ? "  → " + extra : "")); }
}

function mkdirp(rel, files) {
  const full = realpath.join(BASE, rel);
  realfs.mkdirSync(full, { recursive: true });
  for (const f of (files || [])) {
    const fp = realpath.join(full, f);
    realfs.mkdirSync(realpath.dirname(fp), { recursive: true });
    realfs.writeFileSync(fp, "x");
  }
}

(async () => {
  // 干净的假磁盘
  realfs.rmSync(BASE, { recursive: true, force: true });
  mkdirp("C/Windows");
  mkdirp("C/Program Files");
  mkdirp("D/browser/其它软件");
  mkdirp("D/browser/清空环境-便携版/清空环境-便携版", ["start_comfy.bat", "stop_comfy.bat", "comfy_watchdog.vbs", "ComfyUI/main.py"]);
  mkdirp("E");

  console.log("场景 1：朋友那种布局 D:\\browser\\清空环境-便携版\\清空环境-便携版（多套两层）");
  let r = await T.detectComfyDir();
  check("能找到", r.dir === "D:/browser/清空环境-便携版/清空环境-便携版", JSON.stringify(r));

  console.log("场景 2：装在 E:\\清空环境-便携版（标准位置）");
  mkdirp("E/清空环境-便携版", ["start_comfy.bat", "ComfyUI/main.py"]);
  realfs.rmSync(realpath.join(BASE, "D/browser/清空环境-便携版"), { recursive: true, force: true });
  r = await T.detectComfyDir();
  check("能找到", r.dir === "E:/清空环境-便携版", JSON.stringify(r));

  console.log("场景 3：什么都没装");
  realfs.rmSync(realpath.join(BASE, "E/清空环境-便携版"), { recursive: true, force: true });
  r = await T.detectComfyDir();
  check("返回空", r.dir === "" && r.how === "", JSON.stringify(r));

  console.log("场景 4：假装插件被放在便携包里（<ROOT>\\插件\\cleanbg），上溯查找");
  mkdirp("D/mycomfy/插件/cleanbg", ["main.js"]);
  mkdirp("D/mycomfy", ["start_comfy.bat", "ComfyUI/main.py"]);
  pluginFolder.p = realpath.join(BASE, "D/mycomfy/插件/cleanbg");
  r = await T.detectComfyDir();
  check("上溯找到", r.dir === "D:/mycomfy", JSON.stringify(r));
  pluginFolder.p = null;

  console.log("场景 5：localStorage 记住的目录优先");
  store["cleanbg.comfyDir"] = "D:/mycomfy";
  r = await T.detectComfyDir();
  check("用记住的", r.dir === "D:/mycomfy" && r.how.indexOf("记住") >= 0, JSON.stringify(r));
  delete store["cleanbg.comfyDir"];

  console.log("场景 6：pathExists / launchBat");
  check("存在的文件 true", (await T.pathExists("D:/mycomfy/start_comfy.bat")) === true);
  check("不存在的文件 false", (await T.pathExists("D:/mycomfy/没有这个.bat")) === false);
  check("不存在的盘 false", (await T.pathExists("H:/x/start_comfy.bat")) === false);
  let lr = await T.launchBat("D:/mycomfy/start_comfy.bat", "启动脚本");
  check("启动成功且传的是原生路径", lr.ok === true && launched[0] === "D:\\mycomfy\\start_comfy.bat", JSON.stringify(launched));
  lr = await T.launchBat("D:/mycomfy/没有这个.bat", "启动脚本");
  check("缺文件时报失败", lr.ok === false && String(lr.reason).indexOf("不存在") >= 0, JSON.stringify(lr));

  console.log("场景 7：ensureComfyDir 空目录时自动填上 + 写进 localStorage");
  T.applyComfyDir("");
  T.reset();
  delete store["cleanbg.comfyDir"];
  const d = await T.ensureComfyDir();
  check("自动填上", d === "D:/mycomfy", String(d));
  check("记住了", store["cleanbg.comfyDir"] === "D:/mycomfy", String(store["cleanbg.comfyDir"]));

  console.log("场景 8：两个后端都存在时，优先挑 Photoshop（插件）所在的那个盘");
  // 后端：D:\mycomfy（上一步已建） + E:\清空环境-便携版
  mkdirp("E/清空环境-便携版", ["start_comfy.bat", "ComfyUI/main.py"]);
  // 插件装在 E 盘（模拟 Photoshop 在 E 盘）
  mkdirp("E/Adobe Photoshop 2026/Plug-ins/cleanbg", ["main.js"]);
  pluginFolder.p = realpath.join(BASE, "E/Adobe Photoshop 2026/Plug-ins/cleanbg");
  T.reset();
  delete store["cleanbg.comfyDir"];
  T.applyComfyDir("");
  let d8 = await T.ensureComfyDir();
  check("挑了 E 盘的后端", d8 === "E:/清空环境-便携版", String(d8));
  pluginFolder.p = null;

  console.log("\n结果：" + pass + " 通过 / " + fail + " 失败");
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error("测试崩了：" + (e && e.stack || e)); process.exit(2); });
