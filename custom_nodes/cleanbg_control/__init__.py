"""
cleanbg_control —— 给「清空环境」PS 插件用的一键关闭接口

只做一件事：暴露 POST /cleanbg/shutdown，让本机插件请求 ComfyUI 自己退出（顺便释放显存）。
不参与任何生成流程，不加载任何模型。
"""
import os
import threading
import time

from aiohttp import web

try:
    from server import PromptServer
    _routes = PromptServer.instance.routes
except Exception:  # 万一 ComfyUI 结构变了，也不让它拖垮启动
    _routes = None

NODE_CLASS_MAPPINGS = {}
NODE_DISPLAY_NAME_MAPPINGS = {}


def _die_soon(delay=0.6):
    """稍等一下，让 HTTP 响应先发出去，然后直接退出进程。"""
    time.sleep(delay)
    os._exit(0)


if _routes is not None:
    @_routes.get("/cleanbg/ping")
    async def _ping(request):
        return web.json_response({"ok": True, "app": "cleanbg_control"})

    @_routes.post("/cleanbg/shutdown")
    async def _shutdown(request):
        threading.Thread(target=_die_soon, daemon=True).start()
        return web.json_response({"ok": True, "message": "ComfyUI is shutting down"})
