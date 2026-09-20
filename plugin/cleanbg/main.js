/*
 * 清空环境（本地模型版）· Photoshop UXP 插件
 * 流程：当前文档 → 导出 PNG → 本地 ComfyUI（公开模型 flux-2-klein-9b-fp8）→ 结果置入为新图层
 * 不依赖任何加密模型 / 账号登录。
 */

const photoshop = require("photoshop");
const { app, core, action } = photoshop;
const uxp = require("uxp");
const fs = uxp.storage.localFileSystem;
const shell = uxp.shell;

// ======== 可自行修改的配置 ========
// 后端（便携版）所在目录。一般不用手改：
//   ① 安装脚本会把这里自动填成本机实际路径；
//   ② 就算它没填 / 填错了 / 你事后把这个文件夹挪了地方 —— 插件启动时会自动去找；
//   ③ 面板里也能随时改，改完永久记住（localStorage）。
const COMFY_DIR_DEFAULT = "";
const COMFY_DIR_KEY = "cleanbg.comfyDir";
let COMFY_DIR = "";          // 下面 4 个名字由 applyComfyDir() 派生，下游代码统一用它们
let COMFY_ROOT = "";
let COMFY_START = "";
let COMFY_STOP = "";
let COMFY_WATCHDOG = "";
const API = "http://127.0.0.1:8188";                        // ComfyUI 服务地址

function normalizeDir(v) {
  return String(v == null ? "" : v).trim()
    .replace(/^file:\/{2,}/i, "")     // 顺手兼容 file:/// 写法
    .replace(/\\/g, "/")
    .replace(/\/+$/, "");
}
function applyComfyDir(dir) {
  COMFY_DIR = normalizeDir(dir);
  COMFY_ROOT = COMFY_DIR ? COMFY_DIR + "/ComfyUI" : "";
  COMFY_START = COMFY_DIR ? COMFY_DIR + "/start_comfy.bat" : "";
  COMFY_STOP = COMFY_DIR ? COMFY_DIR + "/stop_comfy.bat" : "";
  COMFY_WATCHDOG = COMFY_DIR ? COMFY_DIR + "/comfy_watchdog.vbs" : "";
}
function loadSavedDir() {
  try { return localStorage.getItem(COMFY_DIR_KEY) || ""; } catch (e) { return ""; }
}
function saveComfyDir() {
  try { localStorage.setItem(COMFY_DIR_KEY, COMFY_DIR); } catch (e) { /* 记不住也不影响这次使用 */ }
}
applyComfyDir(COMFY_DIR_DEFAULT);

// ---------- 后端目录：判断 / 自动查找 ----------
// 原则：读文件用 fs.getEntryWithUrl（存储 API），拉起进程只用 shell.openPath（启动 API）。
//   以前拿 getEntryWithUrl 去"启动" .bat，必然报 "Could not find an entry of …"；
//   openExternal("file:///…") 从 Photoshop 22.5 起被禁，报 "file scheme is not supported"。
async function pathExists(p) {
  try {
    const s = String(p).replace(/\\/g, "/");
    const i = s.lastIndexOf("/");
    if (i <= 0) return false;
    const parent = await fs.getEntryWithUrl("file:///" + s.slice(0, i));
    await parent.getEntry(s.slice(i + 1));
    return true;
  } catch (e) { return false; }
}

function entryPath(e) {
  try { if (e && e.nativePath) return normalizeDir(e.nativePath); } catch (er) { /* 换下一种 */ }
  try { if (e && e.url) return normalizeDir(decodeURI(String(e.url))); } catch (er) { /* 放弃 */ }
  return "";
}

// 一个文件夹算不算"后端目录"——认准里面的 start_comfy.bat
async function isComfyDir(dir) {
  const d = normalizeDir(dir);
  if (!d) return false;
  return await pathExists(d + "/start_comfy.bat");
}

async function listSubDirs(entry) {
  try {
    const es = await entry.getEntries();
    return es.filter((e) => { try { return e.isFolder; } catch (er) { return false; } });
  } catch (e) { return []; }
}

const DIR_NAME_CANDS = ["清空环境-便携版", "清空环境", "ComfyUI-aki-v2", "ComfyUI"];
// 这些名字的文件夹下面会被多看两层（解压出来多套一层目录是常态）
const DIR_CONTAINER_HINTS = ["browser", "download", "desktop", "soft", "tool", "program",
                             "下载", "桌面", "软件", "程序", "应用", "工具",
                             "ai", "comfy", "cleanbg", "清空", "便携"];
function nameLooksLikeDir(name) {
  const n = String(name || "").toLowerCase();
  return DIR_CONTAINER_HINTS.some((h) => n.indexOf(h) >= 0);
}

async function detectComfyDir() {
  // 1) 上次记住的
  const saved = loadSavedDir();
  if (saved && (await isComfyDir(saved))) return { dir: saved, how: "上次记住的目录" };
  // 2) 安装脚本写进代码里的
  if (COMFY_DIR_DEFAULT && (await isComfyDir(COMFY_DIR_DEFAULT))) {
    return { dir: COMFY_DIR_DEFAULT, how: "安装时记录的目录" };
  }
  // 3) 从插件自己所在位置往上找（在便携包内部直接跑插件时有用），顺便记下插件在哪个盘
  let pluginDrive = "";
  try {
    let cur = await fs.getPluginFolder();
    const p0 = entryPath(cur);
    if (/^[A-Za-z]:/.test(p0)) pluginDrive = p0.slice(0, 1).toUpperCase();
    for (let i = 0; i < 4 && cur; i++) {
      let par = null;
      try { par = await cur.getParent(); } catch (er) { break; }
      if (!par) break;
      cur = par;
      const p = entryPath(cur);
      if (p && (await isComfyDir(p))) return { dir: p, how: "插件所在位置往上找" };
    }
  } catch (e) { /* 拿不到插件目录就算了 */ }
  // 4) 各盘符常见位置扫描（深度最多 3 层，只进"看着像"的目录，不会一直扫）
  //    先扫 Photoshop 所在的那个盘（同一台机器上往往装在一起），再扫 C..I
  const drives = [];
  for (const d of [pluginDrive, "C", "D", "E", "F", "G", "H", "I"]) {
    const u = String(d || "").toUpperCase();
    if (u && drives.indexOf(u) === -1) drives.push(u);
  }
  for (const drv of drives) {
    let root = null;
    try { root = await fs.getEntryWithUrl("file:///" + drv + ":/"); } catch (e) { continue; }
    for (const nm of DIR_NAME_CANDS) {
      if (await isComfyDir(drv + ":/" + nm)) return { dir: drv + ":/" + nm, how: drv + ": 盘常见位置" };
      if (await isComfyDir(drv + ":/" + nm + "/" + nm)) {
        return { dir: drv + ":/" + nm + "/" + nm, how: drv + ": 盘常见位置（解压多了一层）" };
      }
    }
    const lv1 = await listSubDirs(root);
    for (const d1 of lv1) {
      const p1 = entryPath(d1);
      if (!p1) continue;
      if (await isComfyDir(p1)) return { dir: p1, how: drv + ": 盘扫到" };
      if (!nameLooksLikeDir(d1.name)) continue;
      const lv2 = await listSubDirs(d1);
      for (const d2 of lv2) {
        const p2 = entryPath(d2);
        if (!p2) continue;
        if (await isComfyDir(p2)) return { dir: p2, how: drv + ": 盘扫到" };
        const lv3 = await listSubDirs(d2);
        for (const d3 of lv3) {
          const p3 = entryPath(d3);
          if (p3 && (await isComfyDir(p3))) return { dir: p3, how: drv + ": 盘扫到（深一层）" };
        }
      }
    }
  }
  return { dir: "", how: "" };
}

// 保证 COMFY_DIR 可用：当前的不对就自动找一次（整个会话只找一次，之后记住）
let dirReadyPromise = null;
function ensureComfyDir() {
  if (!dirReadyPromise) {
    dirReadyPromise = (async () => {
      if (await isComfyDir(COMFY_DIR)) return COMFY_DIR;
      const found = await detectComfyDir();
      if (found.dir) {
        applyComfyDir(found.dir);
        saveComfyDir();
        const el = $("comfyDir");
        if (el) el.value = COMFY_DIR;
        log("已自动找到后端目录（" + found.how + "）：" + COMFY_DIR);
      }
      return COMFY_DIR;
    })();
  }
  return dirReadyPromise;
}

// 可用 LoRA（放在 ComfyUI/models/loras 下，谁在就用谁；全部未加密、可离线）
// 1) F2K9B_ObjectRemover —— 物体移除 LoRA（FLUX.2-klein-base-9B，Modelscope x MuseAI 训练，288 张量）
// 2) BGK2K_6 —— 原作者 Kirameku 公开的「空背景」LoRA（若能拿到）
const LORA_CANDIDATES = [
  { file: "F2K9B_ObjectRemover.safetensors", trigger: "Remove the red highlighted object from the scene.", label: "物体移除 LoRA" },
  { file: "BGK2K_6.safetensors", trigger: "yao", label: "空背景 LoRA（原作者版）" }
];
let ACTIVE_LORA = null;   // 启动时探测，命中第一个存在的

// 自动保护人物的抠像模型（ComfyUI/models/BiRefNet）
const BIREfNET_MODEL = "General";
let BIREfNET_READY = null;   // null=还没探测
// 采样器：默认 beta57（RES4LYF 提供）；如果后端没装那个节点，运行时会自动退化成核心的 beta
let SCHEDULER = "beta57";
// =================================

const DEFAULT_PROMPT =
  "移除画面背景中的所有路人、观众与摄影器材（灯架、柔光箱、三脚架、反光板、摄影包），" +
  "移除地面杂物与电线；严格保持人物的面部、发型、服装、饰品、姿态与原始构图完全不变；" +
  "被移除的区域用周围背景的纹理、透视关系与光照智能补全，过渡自然、无修补痕迹；" +
  "保持原有色调、明暗关系与画面噪点一致，不改变整体风格。";

const $ = (id) => document.getElementById(id);
const statusEl = () => $("status");
let busy = false;

function log(msg) {
  const el = $("log");
  const t = new Date().toTimeString().slice(0, 8);
  el.textContent += `[${t}] ${msg}\n`;
  el.scrollTop = el.scrollHeight;
}
function setStatus(s) { statusEl().textContent = s; }
// 面板「后端目录」下面那行提示（0=普通 1=正常 2=警告）
function setDirHint(msg, level) {
  const el = $("dirHint");
  if (!el) return;
  el.textContent = msg || "";
  el.style.color = (level === 2) ? "#ff8a8a" : ((level === 1) ? "#8fd18f" : "#9a9a9a");
}
function setBusy(b, status) {
  busy = b;
  $("run").disabled = b;
  $("run").textContent = b ? "处理中…" : "▶ 清空环境";
  if (status) setStatus(status);
}

// ---------- 进度条 ----------
let ws = null;
let elapsedTimer = null;
let lastPct = 0;

function setProgress(pct, text) {
  const bar = $("bar");
  if (bar) bar.style.width = Math.max(0, Math.min(100, pct)).toFixed(1) + "%";
  const t = $("barText");
  if (t && text) t.textContent = text;
}

// 进度只升不降（ComfyUI 的节点执行顺序不固定，避免进度条来回跳）
function bump(pct, text) {
  if (pct > lastPct) { lastPct = pct; setProgress(pct, text); }
  else if (text) setProgress(lastPct, text);
}

// 工作流各节点 → 进度阶段（按耗时分布给权重）
const NODE_PHASES = {
  "21": [22, "加载主模型…"],
  "22": [24, "加载文本编码器…"],
  "23": [26, "加载 VAE…"],
  "19": [27, "读取图片…"],
  "90": [28, "按比例缩放输入…"],
  "91": [29, "读取尺寸…"],
  "24": [29, "准备提示词…"],
  "25": [30, "构建编辑条件…"],
  "26": [31, "采样中…"],
  "27": [70, "VAE 解码…"],
  "30": [74, "加载放大模型…"],
  "31": [78, "4 倍放大补细节…"],
  "102": [86, "读取源图尺寸…"],
  "32": [88, "还原到文档尺寸…"],
  "34": [90, "准备颜色参照…"],
  "33": [92, "颜色匹配…"],
  "35": [94, "按蒙版合成…"],
  "41": [96, "保存输出…"],
  // 人物保护 / 选区蒙版分支
  "60": [27, "加载抠像模型…"],
  "61": [29, "识别并抠出人物…"],
  "62": [30, "生成背景蒙版…"],
  "70": [27, "读取选区蒙版…"]
};

function openProgressSocket(clientId) {
  lastPct = 0;
  setProgress(2, "连接进度通道…");
  try {
    ws = new WebSocket(`ws://127.0.0.1:8188/ws?clientId=${clientId}`);
    ws.onopen = () => { log("进度通道已连接"); bump(3, "已提交，排队中…"); };
    ws.onerror = () => { log("进度通道不可用（进度改为估算）"); ws = null; };
    ws.onclose = () => { ws = null; };
    ws.onmessage = (ev) => {
      let m;
      try { m = JSON.parse(ev.data); } catch (e) { return; }
      const d = m.data || {};

      if (m.type === "execution_start") { bump(4, "开始执行…"); return; }
      if (m.type === "execution_success") { bump(99, "生成完成…"); return; }

      // 采样步进（新版 ComfyUI）
      if (m.type === "progress_state") {
        const n = (d.nodes || {})["26"];
        if (n && n.max) {
          const p = n.value / n.max;
          bump(31 + p * 38, `采样中 ${n.value}/${n.max} 步`);
        }
        return;
      }
      // 采样步进（旧版 ComfyUI 兼容）
      if (m.type === "progress") {
        const p = d.max ? d.value / d.max : 0;
        bump(31 + p * 38, `采样中 ${d.value}/${d.max} 步`);
        return;
      }
      if (m.type === "executing") {
        if (d.node === null) { bump(97, "收尾…"); return; }
        const ph = NODE_PHASES[d.node];
        if (ph) bump(ph[0], ph[1]);
      }
    };
  } catch (e) { ws = null; }
}

function closeProgressSocket() {
  try { if (ws) ws.close(); } catch (e) {}
  ws = null;
}

// ---------- 工具 ----------
async function fetchTimeout(url, opt = {}, ms = 5000) {
  let ctrl = null, timer = null;
  try {
    if (typeof AbortController !== "undefined") {
      ctrl = new AbortController();
      timer = setTimeout(() => { try { ctrl.abort(); } catch (e) {} }, ms);
    }
  } catch (e) { ctrl = null; }
  try {
    const o = Object.assign({}, opt);
    if (ctrl) o.signal = ctrl.signal;
    return await fetch(url, o);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

async function comfyOnline() {
  try {
    const r = await fetchTimeout(`${API}/system_stats`, { method: "GET" }, 4000);
    return r.ok;
  } catch (e) {
    return false;
  }
}

// ---------- 导出当前文档到 ComfyUI/input ----------
async function exportToComfyInput(fileName) {
  const folder = await fs.getEntryWithUrl("file:///" + COMFY_ROOT + "/input");
  const file = await folder.createFile(fileName, { overwrite: true });
  await core.executeAsModal(async () => {
    await app.activeDocument.saveAs.png(file, { compression: 6 }, true); // asCopy=true，不改动原文档
  }, { commandName: "导出 PNG 供本地模型处理" });
  return file;
}

// ---------- 把 PS 选区导出成黑白蒙版 PNG（白=选中=要重绘）----------
// 坑：PS 2026 里"复制文档"不保留选区，所以顺序必须是
//     ① 选区先存成临时通道 → ② 复制文档（通道跟着走）→ ③ 拼合 → ④ 从通道取回选区
//     → ⑤ 反选填黑、再反选填白 → ⑥ 导出 PNG → ⑦ 关临时文档、删临时通道。
// 全程只新增/删除一个临时通道，源文档的图层像素一个都不动。
const SEL_CHANNEL = "_cleanbg_sel";
const MASK_DOC_NAME = "cleanbg_mask_tmp";

async function exportSelectionMask(fileName) {
  const folder = await fs.getEntryWithUrl("file:///" + COMFY_ROOT + "/input");
  const file = await folder.createFile(fileName, { overwrite: true });

  const fill = (color) => ({
    _obj: "fill",
    using: { _enum: "fillContents", _value: color },
    opacity: { _unit: "percentUnit", _value: 100 },
    mode: { _enum: "blendMode", _value: "normal" }
  });
  const bp = (desc) => action.batchPlay([desc], { synchronousExecution: true });

  await core.executeAsModal(async () => {
    const srcId = app.activeDocument.id;
    let tmpId = null;
    try {
      // 0) 清掉上次可能残留的同名通道
      try { await bp({ _obj: "delete", _target: [{ _ref: "channel", _name: SEL_CHANNEL }] }); } catch (e) {}

      // 1) 选区 → 临时通道
      await bp({
        _obj: "duplicate",
        _target: [{ _ref: "channel", _property: "selection" }],
        name: SEL_CHANNEL
      });
      log("选区已存入临时通道 " + SEL_CHANNEL);

      // 2) 复制文档（通道会跟着复制过去）
      await bp({ _obj: "duplicate", _target: [{ _ref: "document", _id: srcId }], name: MASK_DOC_NAME });
      const docs = app.documents;
      for (let i = 0; i < docs.length; i++) {
        if (docs[i].name === MASK_DOC_NAME) tmpId = docs[i].id;
      }
      if (!tmpId) throw new Error("没找到临时蒙版文档 " + MASK_DOC_NAME);
      await bp({ _obj: "select", _target: [{ _ref: "document", _id: tmpId }] });

      // 3) 拼合，再从通道把选区取回来（拼合会丢选区）
      await bp({ _obj: "flattenImage" });
      await bp({
        _obj: "set",
        _target: [{ _ref: "channel", _property: "selection" }],
        to: { _ref: "channel", _name: SEL_CHANNEL }
      });

      // 4) 反选填黑（选区外黑），再反选填白（选区内白）
      await bp({ _obj: "inverse" });
      await bp(fill("black"));
      await bp({ _obj: "inverse" });
      await bp(fill("white"));

      // 5) 导出
      await app.activeDocument.saveAs.png(file, { compression: 6 }, true);
      log("选区蒙版已导出：" + fileName);
    } finally {
      try {
        if (tmpId) {
          await bp({
            _obj: "close", _target: [{ _ref: "document", _id: tmpId }],
            saving: { _enum: "saveOptions", _value: "no" }
          });
        }
      } catch (e) { log("临时蒙版文档关闭失败（可手动关掉它）：" + (e.message || e)); }
      try {
        await bp({ _obj: "select", _target: [{ _ref: "document", _id: srcId }] });
        await bp({ _obj: "delete", _target: [{ _ref: "channel", _name: SEL_CHANNEL }] });
        log("临时通道已清理");
      } catch (e) {
        log("临时通道清理失败（可在通道面板手动删掉 " + SEL_CHANNEL + "）：" + (e.message || e));
      }
    }
  }, { commandName: "导出选区蒙版供本地模型处理" });

  return file;
}

// ---------- 组装工作流 ----------
// 关键点：尺寸不问 Photoshop 要（300DPI 文档下 PS 会按"点"返回，导致尺寸错 4.17 倍），
//        改由 ComfyUI 自己量源图像素尺寸（GetImageSize+），生成规模按总像素数自动等比缩放。
function buildWorkflow(srcName, maskName, megapixels, prompt, steps, opts) {
  opts = opts || {};
  const rs = {
    upscale_method: "lanczos",
    keep_proportion: "stretch",
    pad_color: "0, 0, 0",
    crop_position: "center",
    device: "cpu"
  };
  const wf = {
    // ---- 源图 + 按总像素等比缩放到生成规模 ----
    "19": { class_type: "LoadImage", inputs: { image: srcName } },
    "90": {
      class_type: "ImageScaleToTotalPixels",
      inputs: { image: ["19", 0], upscale_method: "lanczos", megapixels: megapixels, resolution_steps: 8 }
    },
    "91": { class_type: "GetImageSize+", inputs: { image: ["90", 0] } },

    // ---- 模型 ----
    "21": { class_type: "UNETLoader", inputs: { unet_name: "flux-2-klein-9b-fp8.safetensors", weight_dtype: "default" } },
    "22": { class_type: "CLIPLoader", inputs: { clip_name: "qwen_3_8b_fp8mixed.safetensors", type: "flux2", device: "default" } },
    "23": { class_type: "VAELoader", inputs: { vae_name: "flux2-vae.safetensors" } },
    "24": { class_type: "PrimitiveStringMultiline", inputs: { value: prompt } },
    "25": {
      class_type: "PainterFluxImageEdit",
      inputs: {
        prompt: ["24", 0], mode: "1_image", batch_size: 1,
        width: ["91", 0], height: ["91", 1],
        clip: ["22", 0], vae: ["23", 0], image1: ["90", 0]
      }
    },
    "26": {
      class_type: "KSampler",
      inputs: {
        model: ["21", 0], seed: Math.floor(Math.random() * 2147483647), steps: steps, cfg: 1,
        sampler_name: "euler", scheduler: SCHEDULER, denoise: 1,
        positive: ["25", 0], negative: ["25", 1], latent_image: ["25", 2]
      }
    },
    "27": { class_type: "VAEDecode", inputs: { samples: ["26", 0], vae: ["23", 0] } },

    // ---- 4 倍放大补细节（解决"分辨率低"），再还原到源图像素尺寸 ----
    "30": { class_type: "UpscaleModelLoader", inputs: { model_name: "4x-UltraSharp.pth" } },
    "31": { class_type: "ImageUpscaleWithModel", inputs: { upscale_model: ["30", 0], image: ["27", 0] } },
    "102": { class_type: "GetImageSize+", inputs: { image: ["19", 0] } },   // 源图真实像素尺寸
    "32": {
      class_type: "ImageResizeKJv2",
      inputs: Object.assign({}, rs, { image: ["31", 0], width: ["102", 0], height: ["102", 1], divisible_by: 8 })
    },

    // ---- 颜色匹配回原图（解决"颜色会变"），用原图同尺寸版本作参照 ----
    "34": {
      class_type: "ImageResizeKJv2",
      inputs: Object.assign({}, rs, { image: ["19", 0], mask: ["19", 1], width: ["102", 0], height: ["102", 1], divisible_by: 8 })
    },
    "33": {
      class_type: "ColorMatch",
      inputs: { image_ref: ["34", 0], image_target: ["32", 0], method: "mkl", strength: 1.0, multithread: true }
    },

    "41": { class_type: "SaveImage", inputs: { images: ["33", 0], filename_prefix: "cleanbg" } }
  };

  // ---------- 蒙版局部重绘：人物保护 / PS 选区 ----------
  // image1_mask 在 PainterFluxImageEdit 里会成为 latent 的 noise_mask：1=重绘、0=保留原样。
  // 拿到结果后再用同一蒙版做像素级合成，保证蒙版之外一个像素都不变。
  let maskRef = null, maskImgRef = null;

  if (opts.mode === "protect") {
    // BiRefNet 自动抠人 → 外扩 8px → 取反 = 背景
    wf["60"] = { class_type: "AutoDownloadBiRefNetModel", inputs: { model_name: BIREfNET_MODEL, device: "AUTO", dtype: "float16" } };
    wf["61"] = { class_type: "GetMaskByBiRefNet", inputs: { model: ["60", 0], images: ["90", 0], width: 1024, height: 1024, upscale_method: "bilinear", mask_threshold: 0.0 } };
    wf["62"] = { class_type: "GrowMask", inputs: { mask: ["61", 0], expand: 8, tapered_corners: true } };
    wf["63"] = { class_type: "InvertMask", inputs: { mask: ["62", 0] } };
    wf["64"] = { class_type: "MaskToImage", inputs: { mask: ["63", 0] } };
    maskRef = ["63", 0];
    maskImgRef = ["64", 0];
  } else if (opts.mode === "sel" && maskName) {
    // PS 选区导出成黑白蒙版（白=选中=要重绘）
    wf["70"] = { class_type: "LoadImage", inputs: { image: maskName } };
    wf["71"] = { class_type: "ImageToMask", inputs: { image: ["70", 0], channel: "red" } };
    let ref = ["71", 0];
    if (opts.invertSel) {
      wf["72"] = { class_type: "InvertMask", inputs: { mask: ["71", 0] } };
      ref = ["72", 0];
    }
    wf["73"] = { class_type: "MaskToImage", inputs: { mask: ref } };
    maskRef = ref;
    maskImgRef = ["73", 0];
  }

  if (maskRef) {
    wf["25"].inputs.image1_mask = maskRef;
    wf["65"] = {
      class_type: "ImageResizeKJv2",
      inputs: Object.assign({}, rs, { image: maskImgRef, width: ["102", 0], height: ["102", 1], divisible_by: 8, upscale_method: "bilinear" })
    };
    wf["66"] = { class_type: "ImageToMask", inputs: { image: ["65", 0], channel: "red" } };
    wf["35"] = {
      class_type: "ImageCompositeMasked",
      inputs: { destination: ["34", 0], source: ["33", 0], x: 0, y: 0, resize_source: false, mask: ["66", 0] }
    };
    wf["41"] = { class_type: "SaveImage", inputs: { images: ["35", 0], filename_prefix: "cleanbg" } };
  }

  // 可选：叠加 LoRA（未加密、可离线）
  if (opts.loraFile) {
    wf["50"] = {
      class_type: "LoraLoaderModelOnly",
      inputs: { model: ["21", 0], lora_name: opts.loraFile, strength_model: opts.loraStrength || 1.0 }
    };
    wf["26"].inputs.model = ["50", 0];
  }
  return wf;
}
    

// ---------- 提交并等待 ----------
async function submitAndWait(wf, onProgress) {
  const clientId = "cleanbg-" + Date.now();

  // 开进度通道 + 秒表
  openProgressSocket(clientId);
  const t0 = Date.now();
  if (elapsedTimer) clearInterval(elapsedTimer);
  elapsedTimer = setInterval(() => {
    const s = Math.round((Date.now() - t0) / 1000);
    const t = $("barText");
    if (t) t.textContent = t.textContent.replace(/\s*·\s*\d+s$/, "") + "  ·  " + s + "s";
  }, 1000);

  const resp = await fetch(`${API}/prompt`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ prompt: wf, client_id: clientId })
  });
  if (!resp.ok) {
    const txt = await resp.text();
    throw new Error("ComfyUI 拒绝执行：\n" + txt.slice(0, 600));
  }
  const { prompt_id } = await resp.json();

  let running = false;
  while (Date.now() - t0 < 20 * 60 * 1000) {
    await new Promise((r) => setTimeout(r, 1500));
    let hist;
    try {
      const hr = await fetchTimeout(`${API}/history/${prompt_id}`, { method: "GET" }, 15000);
      hist = await hr.json();
    } catch (e) {
      continue;
    }
    if (!running) { running = true; onProgress("模型执行中…"); }
    setStatus(`模型执行中… ${Math.round((Date.now() - t0) / 1000)}s`);
    if (hist[prompt_id]) {
      const entry = hist[prompt_id];
      const st = (entry.status && entry.status.status_str) || "";
      if (st === "error") {
        const msgs = (entry.status.messages || []).map((m) => JSON.stringify(m)).join("\n");
        throw new Error("ComfyUI 执行报错：\n" + msgs.slice(0, 1000));
      }
      const outputs = entry.outputs || {};
      for (const nid in outputs) {
        const imgs = outputs[nid].images || [];
        if (imgs.length) return imgs[imgs.length - 1];
      }
      throw new Error("执行结束但没有拿到输出图片");
    }
  }
  throw new Error("等待超时（20 分钟）");
}

// ---------- 结果置入 PS ----------
async function placeResult(fileName, docId, addSelMask) {
  const folder = await fs.getEntryWithUrl("file:///" + COMFY_ROOT + "/output");
  const entry = await folder.getEntry(fileName);
  const token = await fs.createSessionToken(entry);
  await core.executeAsModal(async () => {
    // 若用户中途切了文档，先切回来，保证结果落在发起时的文档上
    try {
      if (!app.activeDocument || app.activeDocument.id !== docId) {
        await action.batchPlay([{
          _obj: "select", _target: [{ _ref: "document", _id: docId }]
        }], {});
      }
    } catch (e) { /* 文档已关闭则忽略 */ }

    await action.batchPlay([{
      _obj: "placeEvent",
      null: { _path: token, _kind: "local" },
      freeTransformCenterState: { _enum: "quadCenterState", _value: "QCSAverage" },
      offset: { _obj: "offset", horizontal: { _unit: "pixelsUnit", _value: 0 }, vertical: { _unit: "pixelsUnit", _value: 0 } }
    }], { synchronousExecution: false });

    try {
      const lay = app.activeDocument.activeLayers[0];
      if (lay) lay.name = "清空环境";
    } catch (e) { /* 改名失败不影响结果 */ }

    // 有选区就给结果图层加蒙版：只改选区内的区域（失败也不影响结果）
    // 注：选区蒙版模式已经在生成时限定范围了，不用再加一次
    if (addSelMask !== false) try {
      await action.batchPlay([{ _obj: "get", _target: [{ _property: "selection" }, { _ref: "document", _id: docId }] }], {});
      await action.batchPlay([{
        _obj: "make",
        _target: [{ _ref: "channel" }],
        at: { _ref: "channel", _enum: "channel", _value: "mask" },
        using: { _enum: "userMaskEnabled", _value: "revealSelection" }
      }], {});
    } catch (e) { /* 无选区或加蒙版失败：整层生效 */ }
  }, { commandName: "置入清空环境结果" });
}

// ---------- 主流程 ----------
async function run() {
  if (busy) return;
  const doc = app.activeDocument;
  if (!doc) { setStatus("请先打开一张图片"); return; }

  setBusy(true, "检查 ComfyUI …");
  setProgress(2, "检查后端…");
  try {
    await ensureComfyDir();
    if (!COMFY_ROOT) {
      setDirHint("还没设置后端目录：点【自动查找】，或手动填便携版文件夹后点【应用】", 2);
      log("无法开工：插件还不知道后端在哪（面板「后端目录」是空的）");
      setBusy(false, "后端目录未设置");
      return;
    }
    if (!(await comfyOnline())) {
      log("ComfyUI 未运行，请点【启动 ComfyUI】并等待 1-2 分钟后再试");
      setBusy(false, "ComfyUI 未运行");
      return;
    }
    log("ComfyUI 在线");

    // 采样器探测：没装 RES4LYF 的后端没有 beta57，自动退化成核心的 beta
    try {
      const r = await fetchTimeout(`${API}/object_info/KSampler`, { method: "GET" }, 20000);
      const j = await r.json();
      const list = ((((j.KSampler || {}).input || {}).required || {}).scheduler) || [];
      const opts = list[0] || [];
      if (Array.isArray(opts) && opts.length && opts.indexOf("beta57") === -1) {
        if (opts.indexOf("beta") !== -1) {
          SCHEDULER = "beta";
          log("后端没有 beta57 采样器（未装 RES4LYF 节点），本次改用 beta 采样器");
        } else {
          log("警告：后端没有 beta57 也没有 beta 采样器，将用默认值重试");
        }
      }
    } catch (e) {
      log("采样器探测失败（不影响运行）：" + (e && e.message ? e.message : e));
    }

    // 选区检测：有选区时，结果图层会自动加蒙版（只改选区内的区域）
    let hasSel = false;
    try {
      await action.batchPlay([{ _obj: "get", _target: [{ _property: "selection" }, { _ref: "document", _id: doc.id }] }], {});
      hasSel = true;
      log("检测到选区：结果将只改选区内的区域");
    } catch (e) { hasSel = false; }

    const megapixels = parseFloat($("quality").value) || 2.9;
    const steps = parseInt($("steps").value, 10);
    log(`生成规模 ${megapixels}MP（3:2 时约 ${Math.round(Math.sqrt(megapixels * 1e6 * 1.5))} 长边），步数 ${steps}`);
    log("尺寸由 ComfyUI 实测源图像素，不依赖 PS 的单位设置");

    setStatus("导出当前文档…");
    setProgress(6, "导出文档…");
    const fileName = `ps_cleanbg_${Date.now()}.png`;
    await exportToComfyInput(fileName);
    log("已导出：" + fileName);

    const prompt0 = ($("prompt").value || "").trim() || DEFAULT_PROMPT;

    // 处理范围：整图 / 自动保护人物 / 仅 PS 选区
    let mode = "full";
    try { mode = $("range").value || "full"; } catch (e) { mode = "full"; }
    let invertSel = false;
    try { invertSel = !!($("invertSel") && $("invertSel").checked); } catch (e) { invertSel = false; }

    let maskName = null;
    if (mode === "protect" && BIREfNET_READY === false) {
      log("没找到人物抠像模型，本次按「整图重绘」处理");
      mode = "full";
    }
    if (mode === "sel") {
      if (!hasSel) {
        log("选了「仅清理 PS 选区」，但当前没有选区 —— 请先用选框/套索工具框出要清理的区域");
        setProgress(0, "没有选区");
        setBusy(false, "没有选区");
        return;
      }
      setStatus("导出选区蒙版…");
      setProgress(7, "导出选区蒙版…");
      maskName = `ps_cleanbg_mask_${Date.now()}.png`;
      await exportSelectionMask(maskName);
      log("已导出选区蒙版：" + maskName + (invertSel ? "（反选：保护选区内，清选区外）" : ""));
    } else if (mode === "protect") {
      log("自动保护人物：BiRefNet 抠出人物 → 只重绘背景（人物像素级不动）");
    }

    // LoRA：启动时探测到的文件 + 勾选了才用（触发词加在最前面）
    let useLora = false;
    try { useLora = !!($("useLora") && $("useLora").checked); } catch (e) { useLora = false; }
    let loraFile = null, loraTrigger = "";
    if (useLora && ACTIVE_LORA) { loraFile = ACTIVE_LORA.file; loraTrigger = ACTIVE_LORA.trigger; }
    else if (useLora) log("没找到可用的 LoRA 文件，本次按无 LoRA 运行");
    if (loraFile) log("已启用 LoRA：" + loraFile);

    const prompt = loraFile && loraTrigger ? (loraTrigger + " " + prompt0) : prompt0;
    const wf = buildWorkflow(fileName, maskName, megapixels, prompt, steps, {
      mode: mode, invertSel: invertSel, loraFile: loraFile
    });

    setStatus("提交给本地模型…");
    setProgress(8, "提交任务…");
    log("提交工作流到 ComfyUI");
    const img = await submitAndWait(wf, (m) => log(m));
    log("生成完成：" + img.filename);
    setProgress(98, "置入图层…");

    setStatus("置入图层…");
    await placeResult(img.filename, doc.id, mode !== "sel");
    log("已置入为新图层（智能对象）" + (mode === "sel" ? "，只改了选区内的区域" : (hasSel ? "，并已按选区加蒙版" : "")));
    log("提示：不满意的部分直接用蒙版擦掉即可");
    setProgress(100, "完成 ✔");
    setBusy(false, "完成 ✔");
  } catch (e) {
    const msg = (e && e.message) ? e.message : String(e);
    log("错误：" + msg);
    setProgress(0, "失败");
    setBusy(false, "失败，详见下方日志");
  } finally {
    closeProgressSocket();
    if (elapsedTimer) { clearInterval(elapsedTimer); elapsedTimer = null; }
  }
}

// ---------- 启动 / 关闭 ComfyUI ----------
// 注意：只在用户点按钮时才启动，插件不会自己拉起后端。
// 启动只用一种方式：shell.openPath(原生 Windows 路径)。理由（都是踩过的坑）：
//   · openPath 要的是原生路径（D:\xxx\start_comfy.bat），并且返回值里带真实错误（成功 = 空字符串）
//   · openExternal("file:///…") 自 Photoshop 22.5 起被禁 → "file scheme is not supported"
//   · fs.getEntryWithUrl 是"存储"API，不是"启动"API → 拿它启动只会报 "Could not find an entry of …"
async function launchBat(batPath, label) {
  const native = String(batPath).replace(/\//g, "\\");
  if (!(await pathExists(native))) {
    log("找不到" + label + "：" + native);
    return { ok: false, reason: "文件不存在：" + native };
  }
  try {
    const err = await shell.openPath(native);
    if (err) {
      log(label + "启动失败：" + err);
      return { ok: false, reason: err };
    }
    log(label + "已启动：" + native);
    return { ok: true };
  } catch (e) {
    const msg = e && e.message ? e.message : String(e);
    log(label + "启动失败：" + msg);
    return { ok: false, reason: msg };
  }
}

async function startComfy() {
  try {
    setStatus("正在启动 ComfyUI…");
    setProgress(0, "启动中…");

    // 先确认后端目录（不对就自动找一次）
    await ensureComfyDir();
    if (!COMFY_DIR) {
      setDirHint("还没设置后端目录：点【自动查找】，或手动填便携版文件夹后点【应用】", 2);
      log("启动失败：插件还不知道后端在哪（面板「后端目录」是空的）");
      setProgress(0, "后端目录未设置");
      setStatus("后端目录未设置");
      return;
    }

    if (await comfyOnline()) {
      log("ComfyUI 已经在运行了");
      setProgress(100, "已就绪");
      setStatus("ComfyUI 已就绪");
      await armWatchdog();
      return;
    }

    const res = await launchBat(COMFY_START, "启动脚本");
    if (!res.ok) {
      setDirHint("启动失败：这个目录里没有 start_comfy.bat —— 请检查上面的【后端目录】", 2);
      log("当前后端目录：" + COMFY_DIR);
      log("如果这个文件夹被挪过位置，请把新路径填进「后端目录」并点【应用】（或点【自动查找】）。");
      setProgress(0, "启动失败");
      setStatus("启动失败（看面板「后端目录」）");
      return;
    }

    log("等待后端就绪（首次加载约 1 分钟）…");
    for (let i = 0; i < 45; i++) {
      await new Promise((r) => setTimeout(r, 2000));
      setProgress(Math.min(95, (i + 1) * 2.1), `启动中… ${(i + 1) * 2}s`);
      if (await comfyOnline()) {
        setProgress(100, "就绪 ✔");
        log("ComfyUI 已就绪，可以开工了");
        setStatus("ComfyUI 已就绪");
        await armWatchdog();
        return;
      }
    }
    setProgress(0, "启动超时");
    log("等了 90 秒还没就绪。如果那个命令行窗口里有报错，把它发我");
    setStatus("启动超时");
  } catch (e) {
    log("启动失败：" + (e && e.message ? e.message : e) + "（可手动双击 " + (COMFY_DIR || "后端目录") + " 里的 start_comfy.bat）");
    setStatus("启动失败");
  }
}

// ---------- 关闭 ComfyUI / 自动关闭看门狗 ----------
let watchdogArmed = false;

// 让「关闭 Photoshop」时后端也一起退出（后台静默跑，可重复调用）
async function armWatchdog() {
  if (watchdogArmed) return;
  const res = await launchBat(COMFY_WATCHDOG, "看门狗");
  if (res.ok) {
    watchdogArmed = true;
    log("已启用「关闭 Photoshop 后自动关闭后端」");
  } else {
    log("看门狗启动失败（不影响使用，只是关 PS 时后端不会自动退）");
  }
}

async function stopComfy() {
  try {
    setStatus("正在关闭 ComfyUI…");
    setProgress(0, "关闭中…");
    let sent = false;

    // 方式一（首选）：调用后端自带的关闭接口（优雅退出、干净释放显存）
    try {
      const r = await fetchTimeout(API + "/cleanbg/shutdown", { method: "POST" }, 6000);
      if (r && r.ok) { sent = true; log("已发送关闭指令"); }
    } catch (e) { /* 接口不存在就走方式二 */ }

    // 方式二（兜底）：跑关闭脚本
    if (!sent) {
      log("关闭接口不可用，改用脚本方式…");
      try {
        const r2 = await launchBat(COMFY_STOP, "关闭脚本");
        sent = r2.ok;
      } catch (e) {
        log("脚本方式也失败：" + (e.message || e));
      }
    }

    // 等它真的关掉
    for (let i = 0; i < 25; i++) {
      await new Promise((r) => setTimeout(r, 1000));
      if (!(await comfyOnline())) {
        setProgress(100, "已关闭");
        log("ComfyUI 已关闭，显存已释放");
        setStatus("ComfyUI 已关闭");
        return;
      }
    }
    setProgress(0, "关闭超时");
    log("等了 25 秒服务还在，可手动双击 " + (COMFY_DIR || "后端目录") + " 里的 stop_comfy.bat");
    setStatus("关闭超时");
  } catch (e) {
    log("关闭失败：" + (e.message || e) + "（可手动双击 " + (COMFY_DIR || "后端目录") + " 里的 stop_comfy.bat）");
    setStatus("关闭失败");
  }
}

// ---------- 初始化 ----------
(function init() {
  $("prompt").value = DEFAULT_PROMPT;
  $("run").addEventListener("click", run);
  $("startComfy").addEventListener("click", startComfy);
  $("stopComfy").addEventListener("click", stopComfy);

  // 处理范围切换：只有「仅清理 PS 选区」才显示反选
  try {
    $("range").addEventListener("change", () => {
      $("invertRow").style.display = ($("range").value === "sel") ? "block" : "none";
    });
  } catch (e) { /* 忽略 */ }

  setProgress(0, "就绪");
  log("插件已加载（后端不会自动启动，需要时点【启动 ComfyUI】）");

  // 后端目录：可改、可记住（把文件夹挪了位置也不用改代码）
  try {
    const dirEl = $("comfyDir");
    const applyDirFromPanel = async () => {
      const v = String(dirEl.value || "").trim();
      if (!v) { setDirHint("目录不能为空", 2); return; }
      applyComfyDir(v);
      saveComfyDir();
      dirEl.value = COMFY_DIR;
      dirReadyPromise = null;            // 让下次使用重新按新目录判断
      const good = await isComfyDir(COMFY_DIR);
      setDirHint(good ? ("已记住：" + COMFY_DIR) : "这个目录里没有 start_comfy.bat，请确认路径填对了", good ? 1 : 2);
      log("后端目录已改为：" + COMFY_DIR + (good ? "" : "（警告：没找到 start_comfy.bat）"));
      setStatus((await comfyOnline()) ? "ComfyUI 已就绪" : "ComfyUI 未运行");
    };
    if (dirEl) {
      dirEl.value = COMFY_DIR || "";
      const sb = $("comfyDirSave");
      if (sb) sb.addEventListener("click", applyDirFromPanel);
      dirEl.addEventListener("keydown", (e) => { if (e.key === "Enter") applyDirFromPanel(); });
      const ab = $("comfyDirAuto");
      if (ab) ab.addEventListener("click", async () => {
        setDirHint("正在自动查找后端目录…", 0);
        try { localStorage.removeItem(COMFY_DIR_KEY); } catch (e) { /* 忽略 */ }
        applyComfyDir("");
        dirReadyPromise = null;
        const d = await ensureComfyDir();
        dirEl.value = d || "";
        setDirHint(d ? ("已找到并记住：" + d) : "没找到 —— 请手动填写便携版文件夹后点【应用】", d ? 1 : 2);
      });
    }
  } catch (e) { /* 忽略 */ }

  // 后台自动定位一次后端目录（找不到也不影响其它功能）
  (async () => {
    try {
      const d = await ensureComfyDir();
      const dirEl = $("comfyDir");
      if (dirEl && d) dirEl.value = d;
      if (d) setDirHint("后端目录：" + d, 1);
      else setDirHint("没找到后端目录 —— 点【自动查找】，或手动填写便携版文件夹后点【应用】", 2);
    } catch (e) { /* 忽略 */ }
  })();

  // 探测 LoRA（谁在就用谁）
  (async () => {
    const nameEl = $("loraName");
    await ensureComfyDir();
    if (!COMFY_ROOT) {
      if (nameEl) nameEl.textContent = "后端目录未设置";
      const cb0 = $("useLora");
      if (cb0) { cb0.checked = false; cb0.disabled = true; }
      return;
    }
    for (const c of LORA_CANDIDATES) {
      try {
        await fs.getEntryWithUrl("file:///" + encodeURI(COMFY_ROOT + "/models/loras/" + c.file));
        ACTIVE_LORA = c;
        break;
      } catch (e) { /* 试下一个 */ }
    }
    if (ACTIVE_LORA) {
      if (nameEl) nameEl.textContent = ACTIVE_LORA.label + "（" + ACTIVE_LORA.file + "）";
      log("LoRA 已就位：" + ACTIVE_LORA.file);
    } else {
      if (nameEl) nameEl.textContent = "未安装（不需要也能用）";
      const cb = $("useLora");
      if (cb) { cb.checked = false; cb.disabled = true; }
      log("未发现可用的 LoRA 文件（" + COMFY_ROOT + "/models/loras/），该选项已禁用");
    }
  })();

  // 抠像模型（自动保护人物用）
  (async () => {
    await ensureComfyDir();
    if (!COMFY_ROOT) { BIREfNET_READY = false; return; }
    try {
      await fs.getEntryWithUrl("file:///" + encodeURI(COMFY_ROOT + "/models/BiRefNet/" + BIREfNET_MODEL + ".safetensors"));
      BIREfNET_READY = true;
      log("人物抠像模型已就位：BiRefNet/" + BIREfNET_MODEL + ".safetensors");
    } catch (e) {
      BIREfNET_READY = false;
      log("未安装人物抠像模型（models/BiRefNet/" + BIREfNET_MODEL + ".safetensors）：「自动保护人物」会退回整图重绘");
    }
  })();

  comfyOnline().then((ok) => {
    if (ok) {
      setStatus("ComfyUI 已就绪");
      log("检测到本地 ComfyUI 在线");
      armWatchdog();   // 后端在跑才装看门狗：关掉 PS 时顺手关掉它
    } else {
      setStatus("ComfyUI 未运行");
      log("未检测到 ComfyUI —— 点【启动 ComfyUI】，或双击" + (COMFY_DIR || "后端目录") + "里的 start_comfy.bat");
    }
  });
})();
