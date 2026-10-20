#!/usr/bin/env python3
"""本机测试用的 SSH 服务器 —— 不需要 Docker,也不需要 root。

用途:验证 Berth 对「半开连接」的判定。拔网线/断电往往会送 RST,被动路径就能抓到,
测不到主动探测;而把服务端进程 SIGSTOP 冻住,它的内核 socket 还在、还在 ACK,
客户端每个写入都"成功"却永远没人应答,也没有 FIN/RST —— 这才是 NAT 会话过期 /
笔记本睡眠那种断法的忠实复刻。

用法:
    python3 -m venv /tmp/berth-sshtest-venv && /tmp/berth-sshtest-venv/bin/pip install asyncssh
    FAKE_SSHD_PORT=2226 /tmp/berth-sshtest-venv/bin/python docker/test-sshd/fake-sshd.py &

信号文件(默认在 /tmp,文件名带端口):
    /tmp/berth-fake-sshd-<port>.ready   本脚本写完表示端口已就绪
    /tmp/berth-fake-sshd-<port>.freeze  出现即把自己 SIGSTOP(外部 kill -CONT 解冻)

用文件而不是管理端口,是因为 Swift 侧要裸写 POSIX socket 才能连,测试里不值当。
"""

import asyncio
import os
import signal
import subprocess
import sys

try:
    import asyncssh
except ImportError:
    sys.exit("缺少 asyncssh。用 venv 里的 python 跑本脚本,或:pip install asyncssh")

USER = os.environ.get("FAKE_SSHD_USER", "dev")
PASSWORD = os.environ.get("FAKE_SSHD_PASSWORD", "berth-spike")
PORT = int(os.environ.get("FAKE_SSHD_PORT", "2226"))
HOST_KEY = os.environ.get("FAKE_SSHD_HOST_KEY", "/tmp/berth-fake-sshd-ed25519")
READY_FILE = "/tmp/berth-fake-sshd-%d.ready" % PORT
FREEZE_FILE = "/tmp/berth-fake-sshd-%d.freeze" % PORT


def ensure_host_key():
    """测试专用 host key。不存在就生成一份,免得 asyncssh 去找 /etc/ssh 下的(root 才读得到)。"""
    if not os.path.exists(HOST_KEY):
        subprocess.run(
            ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", HOST_KEY],
            check=True)


class Server(asyncssh.SSHServer):
    """口令认证。堡垒机/MFA 之类不在本脚本职责内。"""

    def begin_auth(self, username):
        return True

    def password_auth_supported(self):
        return True

    def validate_password(self, username, password):
        return username == USER and password == PASSWORD


async def process_factory(proc):
    """把 exec / shell 请求落到本地子进程。

    探测用的 `execute("true")` 走 exec,终端通道走的 PTY + shell,两条都要有,
    否则 Berth 的 withPTY 开不起来,测试到不了 .connected。
    """
    command = proc.command or os.environ.get("FAKE_SSHD_SHELL", "sh")
    child = await asyncio.create_subprocess_shell(
        command,
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        env={**os.environ, "PS1": "fake$ "})
    await proc.redirect(stdin=child.stdin, stdout=child.stdout,
                        stderr=child.stderr)
    await child.wait()
    try:
        proc.exit(child.returncode or 0)
    except Exception:  # noqa: BLE001 - 通道可能已被客户端关掉,不影响本脚本用途
        pass


async def watch_for_freeze():
    """出现 freeze 信号文件就把自己 SIGSTOP。

    冻住后事件循环不再处理任何 SSH 报文,而内核仍握着已建立的连接继续 ACK 对端每个
    字节 —— 客户端写谁都不报错、也等不到任何回应,正是半开。解冻只能来自外部 SIGCONT。
    删掉信号文件,免得解冻之后立刻又被同一份文件冻回去。
    """
    while True:
        if os.path.exists(FREEZE_FILE):
            os.unlink(FREEZE_FILE)
            os.kill(os.getpid(), signal.SIGSTOP)
        await asyncio.sleep(0.05)


async def main():
    for path in (READY_FILE, FREEZE_FILE):
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
    ensure_host_key()
    server = await asyncssh.create_server(
        Server, "127.0.0.1", PORT,
        server_host_keys=[HOST_KEY],
        process_factory=process_factory)
    with open(READY_FILE, "w") as handle:
        handle.write("%d\n" % PORT)
    print("READY %d" % PORT, flush=True)
    freezer = asyncio.ensure_future(watch_for_freeze())
    try:
        await asyncio.Future()  # 常驻,由外部 kill 结束
    finally:
        freezer.cancel()
        server.close()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
