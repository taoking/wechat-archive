#!/usr/bin/env python3
"""Foreground, local-only key extraction and Archive v1 workflow (Python stdlib)."""
import argparse
import errno
from datetime import datetime
import json
import os
from pathlib import Path
import plistlib
import pty
import select
import fcntl
import termios
import re
import shutil
import signal
import stat
import subprocess
import sys
import time
import uuid

PROJECT = Path(__file__).resolve().parents[2]
MODULE = Path(__file__).resolve().parent
WORKSPACE = PROJECT / "wechat"


class WorkflowError(Exception):
    """Only intentional, non-secret messages may reach the terminal."""


def private_dir(path):
    if path.is_symlink():
        raise WorkflowError("工作目录不能是符号链接。")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not path.is_dir():
        raise WorkflowError("工作目录无效。")
    path.chmod(0o700)
    return path


def private_json(path, value):
    # Exclusive creation means existing keys and symlink destinations are never overwritten.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)


def run(args, *, log=None, timeout=120):
    if log is None:
        result = subprocess.run(args, capture_output=True, timeout=timeout)
    else:
        with log.open("ab") as stream:
            log.chmod(0o600)
            result = subprocess.run(args, stdout=stream, stderr=subprocess.STDOUT, timeout=timeout)
    if result.returncode:
        raise WorkflowError("本地工具执行失败；请查看本次运行目录的私有日志。")
    return result.stdout if log is None else b""


def wechat_pids():
    result = subprocess.run(["/usr/bin/pgrep", "-u", str(os.getuid()), "-x", "WeChat"], capture_output=True)
    if result.returncode not in (0, 1):
        raise WorkflowError("无法确认微信是否已退出。")
    return [int(value) for value in result.stdout.split()]


def executable(pid):
    return Path(run(["/bin/ps", "-p", str(pid), "-o", "comm="]).decode().strip())


def active_source(pid):
    result = subprocess.run(["/usr/sbin/lsof", "-a", "-p", str(pid), "-Fn"], capture_output=True, text=True)
    roots = {Path(line[1:].split("/db_storage/", 1)[0]) / "db_storage"
             for line in result.stdout.splitlines() if line.startswith("n") and "/db_storage/" in line}
    if len(roots) != 1:
        raise WorkflowError("无法确认唯一微信账号；请登录账号后重试，或明确传入 --db-dir。")
    return roots.pop()


def regular_files(root):
    if root.is_symlink() or not root.is_dir():
        raise WorkflowError("来源必须是实际存在的目录，不能是符号链接。")
    def denied(error):
        raise error
    # Explicit traversal errors must never become 'zero databases'.
    with os.scandir(root):
        pass
    result = {}
    for directory, folders, names in os.walk(root, followlinks=False, onerror=denied):
        base = Path(directory)
        folders[:] = [name for name in folders if not (base / name).is_symlink()]
        for name in names:
            path = base / name
            info = path.lstat()
            if stat.S_ISREG(info.st_mode):
                result[path.relative_to(root).as_posix()] = (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)
    return result


def encrypted_databases(root):
    result = []
    for relative in regular_files(root):
        if relative.endswith(".db"):
            fd = os.open(root / relative, os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(fd, "rb") as stream:
                header = stream.read(16)
            if len(header) != 16:
                raise WorkflowError("数据库文件不完整，未继续。")
            if not header.startswith(b"SQLite format 3\0"):
                result.append(relative)
    if not result:
        raise WorkflowError("未发现加密数据库；请核对来源和终端读取权限。")
    return sorted(result)


def load_keys(path):
    if path.is_symlink() or not path.is_file() or not 0 < path.stat().st_size <= 16 * 1024 * 1024:
        raise WorkflowError("密钥文件类型或大小无效。")
    value = json.loads(path.read_bytes())
    if not isinstance(value, dict) or not value:
        raise WorkflowError("密钥文件为空或格式无效。")
    for relative, item in value.items():
        if not isinstance(relative, str) or relative.startswith("/") or "\\" in relative or any(
                part in ("", ".", "..") for part in relative.split("/")):
            raise WorkflowError("密钥映射包含不安全的相对路径。")
        if not isinstance(item, dict) or not isinstance(item.get("enc_key"), str) or not re.fullmatch(r"[0-9a-fA-F]{64}", item["enc_key"]):
            raise WorkflowError("密钥映射格式无效。")
    return {relative: {"enc_key": item["enc_key"]} for relative, item in value.items()}


def snapshot(source, destination):
    if wechat_pids():
        raise WorkflowError("创建副本前必须完全退出微信。")
    before = regular_files(source)
    require_disk_space(sum(info[2] for info in before.values()))
    if destination.exists() or destination.is_symlink():
        raise WorkflowError("副本目录已存在，未覆盖。")
    private_dir(destination)
    for relative, expected in before.items():
        target = destination / relative
        private_dir(target.parent)
        fd = os.open(source / relative, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "rb") as reader:
            info = os.fstat(reader.fileno())
            if (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns) != expected:
                raise WorkflowError("复制期间来源改变，请退出微信后重新运行。")
            output = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(output, "wb") as writer:
                shutil.copyfileobj(reader, writer)
    if regular_files(source) != before or wechat_pids():
        raise WorkflowError("复制期间来源改变，未使用该副本。")


def require_disk_space(required):
    # Leave room for WeChat writes and filesystem metadata during capture/copy.
    disk_root = WORKSPACE if WORKSPACE.exists() else PROJECT
    if shutil.disk_usage(disk_root).free < required + 512 * 1024 * 1024:
        raise WorkflowError("磁盘空间不足；请先释放空间，或将整个项目移动到容量足够的磁盘。")


def wait_for_user(prompt=""):
    try:
        input(prompt)
    except EOFError:
        raise WorkflowError("交互输入已关闭，未继续操作。") from None


def entitlements(path):
    run(["/usr/bin/codesign", "--verify", "--strict", str(path)])
    # ':-' emits XML even on macOS versions where '-' emits human-readable text.
    return plistlib.loads(run(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(path)]))


def stop_wechat(pid, expected_executable):
    if pid not in wechat_pids():
        return
    if executable(pid) != expected_executable:
        raise WorkflowError("微信进程已变化，停止自动操作。")
    os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 15
    while pid in wechat_pids() and time.monotonic() < deadline:
        time.sleep(0.2)
    if pid in wechat_pids():
        raise WorkflowError("微信未正常退出，请手动完全退出后重试。")


def prepare_copy(app, destination, log):
    if wechat_pids():
        raise WorkflowError("准备临时副本前请完全退出微信。")
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    run(["/usr/bin/codesign", "--verify", "-R", '=anchor apple generic and certificate leaf[subject.OU] = "5A4RE8SF68"', str(app)])
    signature = subprocess.run(["/usr/bin/codesign", "-dvv", str(app)], capture_output=True).stderr.decode()
    if "TeamIdentifier=5A4RE8SF68" not in signature:
        raise WorkflowError("来源不是已验证的腾讯官方签名；请先恢复官方微信。")
    original = entitlements(app)
    require_disk_space(sum(info[2] for info in regular_files(app).values()))
    if destination.exists():
        raise WorkflowError("临时副本已存在，未覆盖。")
    run(["/usr/bin/ditto", str(app), str(destination)], log=log)
    info_path = destination / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    for name in ("SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUAllowsAutomaticUpdates"):
        info[name] = False
    info_path.write_bytes(plistlib.dumps(info))
    # Preserve identity, app groups, sandbox and JIT. Removing them broke startup.
    original["com.apple.security.get-task-allow"] = True
    original["com.apple.security.cs.disable-library-validation"] = True
    permissions = destination.parent / "debug-entitlements.plist"
    permissions.write_bytes(plistlib.dumps(original))
    permissions.chmod(0o600)
    run(["/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", "--entitlements", str(permissions), str(destination)], log=log)
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(destination)])
    # The original app must still verify after preparation.
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])


def build_tools(log, need_native):
    print("正在准备本地归档工具…", flush=True)
    run(["swift", "build", "--package-path", str(PROJECT), "--product", "WeChatArchiveCLI"], log=log, timeout=600)
    binary_dir = Path(run(["swift", "build", "--package-path", str(PROJECT), "--show-bin-path"]).decode().strip())
    native = None
    if need_native:
        if not shutil.which("cargo"):
            raise WorkflowError("首次取钥需要 Rust 工具链，请安装后重新运行（brew install rust）。")
        target = PROJECT / ".build/wechat-keys-native"
        run(["cargo", "build", "--release", "--locked", "--manifest-path", str(MODULE / "native/Cargo.toml"), "--target-dir", str(target)], log=log, timeout=600)
        native = target / "release/wechat-key-extractor"
        permissions = log.parent / "scanner-entitlements.plist"
        permissions.write_bytes(plistlib.dumps({"com.apple.security.cs.debugger": True}))
        permissions.chmod(0o600)
        run(["/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", "--entitlements", str(permissions), str(native)], log=log)
    return binary_dir / "WeChatArchiveCLI", native


def capture(pid, seconds, directory):
    output = directory / "hook-candidates.json"
    log = directory / "capture.log"
    environment = dict(os.environ, WECHAT_CAPTURE_OUTPUT=str(output))
    args = ["/usr/bin/lldb", "--no-lldbinit", "-p", str(pid)]
    master, slave = pty.openpty()
    def terminal_session():
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    child = None
    with log.open("wb") as stream:
        log.chmod(0o600)
        try:
            child = subprocess.Popen(args, stdin=slave, stdout=slave, stderr=slave,
                                     env=environment, preexec_fn=terminal_session)
            os.close(slave)
            slave = None
            os.set_blocking(master, False)
            def drain():
                if select.select([master], [], [], 0.1)[0]:
                    try:
                        data = os.read(master, 65536)
                    except OSError:
                        data = b""
                    if data:
                        stream.write(data)
                        stream.flush()
            command = 'command script import "' + str(MODULE / "capture_keys.py").replace('"', '\\"') + '"\n'
            if child.poll() is not None:
                raise WorkflowError("调试器无法连接临时微信；请核对调试权限与终端权限。")
            os.write(master, command.encode())
            ready_until = time.monotonic() + 20
            while b"CAPTURE_READY:" not in log.read_bytes():
                drain()
                if child.poll() is not None or time.monotonic() >= ready_until:
                    raise WorkflowError("调试器无法连接临时微信；请核对调试权限与终端权限。")
            # Python command handling can flush queued terminal input. Send
            # dependent commands only after their predecessor is acknowledged.
            os.write(master, b'process continue\n')
            until = time.monotonic() + 15
            while f"Process {pid} resuming".encode() not in log.read_bytes():
                drain()
                if child.poll() is not None or time.monotonic() >= until:
                    raise WorkflowError("微信未恢复运行，未开始采集。")
            print(f"请现在在临时微信中点击“进入微信”，并打开要归档的聊天。采集窗口 {seconds} 秒。", flush=True)
            deadline = time.monotonic() + seconds
            heartbeat = time.monotonic() + 1
            while time.monotonic() < deadline:
                drain()
                if child.poll() is not None:
                    raise WorkflowError("调试器提前退出，未将采集当作成功。")
                if time.monotonic() >= heartbeat:
                    os.write(master, b'script capture_keys.resume_breakpoint(lldb.debugger)\n')
                    heartbeat = time.monotonic() + 1
            # Keep LLDB's command interpreter available for a bounded detach.
            os.write(master, b'\x03\n')
            drain()
            os.write(master, b'process detach\n')
            until = time.monotonic() + 15
            while f"Process {pid} detached".encode() not in log.read_bytes():
                drain()
                if child.poll() is not None or time.monotonic() >= until:
                    raise WorkflowError("调试器未正常分离，未继续密钥验证。")
            os.write(master, b'script import capture_keys; print("CAPTURE_STATS", capture_keys.STATS)\n')
            until = time.monotonic() + 5
            while b"CAPTURE_STATS {" not in log.read_bytes():
                drain()
                if child.poll() is not None or time.monotonic() >= until:
                    raise WorkflowError("采集诊断未结束，未继续密钥验证。")
            os.write(master, b'quit\n')
            until = time.monotonic() + 15
            while child.poll() is None and time.monotonic() < until:
                drain()
            drain()
            if child.poll() is None or child.returncode or f"Process {pid} detached".encode() not in log.read_bytes():
                raise WorkflowError("密钥捕获未正常结束，未将此情况当作成功。")
        finally:
            if child is not None and child.poll() is None:
                child.send_signal(signal.SIGINT)
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.terminate()
                    try:
                        child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.wait(timeout=5)
                if pid in wechat_pids():
                    os.kill(pid, signal.SIGCONT)
            os.close(master)
            if slave is not None:
                os.close(slave)
    if not output.exists():
        raise WorkflowError("没有捕获到候选密钥；请确保在采集窗口内登录并打开聊天。")
    return output


def core_command(cli, action, source, keys, report, allowed, *, plain=None, account=None, archive=None, limit=None, configure_viewer=False):
    args = [str(cli), action, "--db-dir", str(source), "--keys", str(keys), "--report", str(report)]
    for name in allowed:
        args.extend(["--allow-missing", name])
    if plain is not None:
        args.extend(["--output", str(plain)])
    if account is not None:
        args.extend(["--account-root", str(account)])
    if archive is not None:
        args.extend(["--archive-output", str(archive)])
    if limit is not None:
        args.extend(["--limit", str(limit)])
    if configure_viewer:
        args.append("--configure-viewer")
    return args


def main(argv=None):
    parser = argparse.ArgumentParser(description="微信取钥、验证、解密与一次性归档；运行数据保存在项目 wechat/。")
    parser.add_argument("action", choices=("keys", "validate", "archive"))
    parser.add_argument("--db-dir", type=Path, help="明确选择 db_storage；省略时只检测当前唯一登录账号")
    parser.add_argument("--keys", type=Path, help="复用已有密钥文件，跳过取钥")
    parser.add_argument("--wechat-app", type=Path, default=Path("/Applications/WeChat.app"))
    parser.add_argument("--prepare-copy", action="store_true", help="同意退出微信并创建、重签独立临时副本；官方应用不变")
    parser.add_argument("--capture-seconds", type=int, default=180)
    parser.add_argument("--allow-missing", action="append", default=[], help="逐项允许缺少密钥的数据库相对路径；禁止通配符")
    parser.add_argument("--keep-keys", action="store_true", help="完整归档结束后保留本次导出的密钥 JSON（包括失败）")
    parser.add_argument("--keep-databases", action="store_true", help="完整归档后保留解密后的普通 SQLite 工作数据库")
    parser.add_argument("--limit", type=int, help="验收时限制归档消息数量；默认导出全部")
    parser.add_argument("--open-viewer", action="store_true", help="完整归档后启动项目查看器")
    options = parser.parse_args(argv)
    if sys.platform != "darwin" or os.geteuid() == 0:
        raise WorkflowError("请在 macOS 当前用户终端运行，不要 sudo 整个流程。")
    if not 5 <= options.capture_seconds <= 300 or (options.limit is not None and options.limit <= 0):
        raise WorkflowError("采集窗口应为 5–300 秒；消息数量上限必须大于 0。")
    if options.action == "validate" and not options.keys:
        raise WorkflowError("验证模式需要 --keys。")
    if options.action != "archive" and (options.limit is not None or options.open_viewer or options.keep_databases or options.keep_keys):
        raise WorkflowError("归档保留选项、--limit 和 --open-viewer 仅适用于完整归档；keys 模式本身会导出密钥。")
    if options.keys and options.prepare_copy:
        raise WorkflowError("复用密钥无需准备微信副本，请移除 --prepare-copy。")
    for name in options.allow_missing:
        if not name.endswith(".db") or name.startswith("/") or any(part in ("", ".", "..") for part in name.split("/")) or any(char in name for char in "\\*?["):
            raise WorkflowError("--allow-missing 必须是精确的数据库相对路径，不能包含通配符。")
    os.umask(0o077)
    private_dir(WORKSPACE)
    run_id = datetime.now().strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:8]
    for folder in ("runs", "keys", "snapshots", "databases", "archives", "runtime"):
        private_dir(WORKSPACE / folder)
    session = private_dir(WORKSPACE / "runs" / run_id)
    print("本次运行目录：" + session.relative_to(PROJECT).as_posix(), flush=True)
    key_dir = private_dir(WORKSPACE / "keys" / run_id)
    keys = key_dir / "all_keys.json"
    log = session / "tools.log"
    source = options.db_dir
    pids = wechat_pids()
    if source is None:
        if len(pids) != 1:
            raise WorkflowError("请登录唯一微信账号，或明确传入 --db-dir。")
        source = active_source(pids[0])
    if not source.is_absolute():
        raise WorkflowError("--db-dir 必须是绝对路径。")
    encrypted = encrypted_databases(source)
    source_bytes = sum(info[2] for info in regular_files(source).values())
    require_disk_space(source_bytes * (2 if options.action == "archive" else 1))
    print(f"已确认可读取 {len(encrypted)} 个加密数据库。", flush=True)
    cli, native = build_tools(log, need_native=options.keys is None)
    temporary_pid = None
    temporary_executable = None
    candidates = None
    runtime = None
    plain = None
    try:
        if options.keys:
            private_json(keys, load_keys(options.keys))
        else:
            if options.prepare_copy:
                if pids:
                    if len(pids) != 1 or active_source(pids[0]) != source:
                        raise WorkflowError("运行中的账号与所选数据库来源不一致。")
                    stop_wechat(pids[0], executable(pids[0]))
                runtime = private_dir(WORKSPACE / "runtime" / run_id)
                copy = runtime / "WeChat-KeyExtraction.app"
                print("正在创建独立的临时微信副本；请等待终端提示后再点击进入微信。", flush=True)
                prepare_copy(options.wechat_app, copy, log)
                temporary_executable = copy / "Contents/MacOS/WeChat"
                run(["/usr/bin/open", "-n", str(copy)])
                until = time.monotonic() + 20
                while time.monotonic() < until:
                    matches = [pid for pid in wechat_pids() if executable(pid) == temporary_executable]
                    if len(matches) == 1:
                        temporary_pid = matches[0]
                        break
                    time.sleep(0.2)
                if temporary_pid is None:
                    raise WorkflowError("临时副本未启动；请保留官方微信并检查本次日志。")
                # Attaching at dyld_start can block application initialization.
                print("请等待临时微信的登录页出现，先不要点击进入微信。", flush=True)
                if not sys.stdin.isatty():
                    raise WorkflowError("首次取钥需要交互式终端确认微信已就绪；请直接运行 command 入口。")
                wait_for_user("登录页出现后，在此终端按回车安装捕获：")
                pid = temporary_pid
            else:
                if len(pids) != 1 or active_source(pids[0]) != source:
                    raise WorkflowError("请先登录所选账号。官方签名需使用 --prepare-copy 准备独立副本。")
                pid = pids[0]
            if entitlements(executable(pid)).get("com.apple.security.get-task-allow") is not True:
                raise WorkflowError("微信不允许调试。请使用 --prepare-copy；不要重签官方应用。")
            candidates = capture(pid, options.capture_seconds, key_dir)
            if active_source(pid) != source or entitlements(executable(pid)).get("com.apple.security.get-task-allow") is not True:
                raise WorkflowError("登录账号或调试签名已变化，未继续取钥。")
            run([str(native), "--pid", str(pid), "--db-dir", str(source), "--candidates", str(candidates), "--output", str(keys)], log=log)
            if temporary_pid is not None:
                stop_wechat(temporary_pid, temporary_executable)
                temporary_pid = None
        if wechat_pids():
            print("请完全退出微信后按回车继续数据库验证与快照。", flush=True)
            if not sys.stdin.isatty():
                raise WorkflowError("微信仍在运行，无法进行无人值守验证或导出。")
            wait_for_user()
            if wechat_pids():
                raise WorkflowError("微信仍在运行，已停止。")
        snapshot_root = WORKSPACE / "snapshots" / run_id
        snapshot(source, snapshot_root)
        action = "archive" if options.action == "archive" else "validate"
        plain = WORKSPACE / "databases" / run_id if action == "archive" else None
        archive = WORKSPACE / "archives" / run_id if action == "archive" else None
        report = session / "result.json"
        result = subprocess.run(core_command(cli, action, snapshot_root, keys, report, options.allow_missing,
            plain=plain, account=source.parent if action == "archive" else None, archive=archive, limit=options.limit,
            configure_viewer=options.open_viewer), capture_output=True)
        if result.returncode:
            raise WorkflowError("数据库验证／归档未完成；缺少密钥须逐项明确 --allow-missing，详情见本次 result.json。")
        summary = json.loads(report.read_bytes())
        private_json(session / "session.json", {"source": str(source), "snapshot": str(snapshot_root), "keys": str(keys), "archive": str(archive) if archive else None})
        print(f"验证成功：{summary['validated']} 个；缺少密钥：{summary['missingKeys']} 个。", flush=True)
        if action == "archive":
            print(f"已导出 {summary['exported']} 个数据库并创建归档。", flush=True)
            print("归档位置：" + archive.relative_to(PROJECT).as_posix())
            if not options.keep_keys:
                keys.unlink()
                print("本次临时密钥已清理；传入 --keep-keys 可显式保留。")
        else:
            print("密钥文件：" + keys.relative_to(PROJECT).as_posix())
        print("结果报告：" + report.relative_to(PROJECT).as_posix())
        if action == "archive" and options.open_viewer:
            run([str(PROJECT / "scripts/run-app.sh")], log=log, timeout=600)
    finally:
        # Also clean a partially captured file when attach/capture itself fails.
        for candidate_file in (key_dir / "hook-candidates.json", key_dir / "hook-candidates.tmp"):
            if candidate_file.exists():
                candidate_file.unlink()
        try:
            if temporary_pid is not None:
                stop_wechat(temporary_pid, temporary_executable)
        finally:
            if options.action == "archive" and not options.keep_keys and keys.exists():
                keys.unlink()
            if options.action == "archive" and not options.keep_databases and plain is not None and plain.exists():
                shutil.rmtree(plain)
            # Never remove an app bundle while its process still uses it.
            if runtime is not None and runtime.exists() and (temporary_pid is None or temporary_pid not in wechat_pids()):
                shutil.rmtree(runtime)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("操作已取消；已完成的私有输出保留。", file=sys.stderr)
        sys.exit(130)
    except WorkflowError as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
    except PermissionError:
        print("文件读取被系统拒绝。请检查实际终端的目录读取权限，授权后重开终端；不要重签官方微信。", file=sys.stderr)
        sys.exit(1)
    except OSError as error:
        if error.errno == errno.ENOSPC:
            print("磁盘空间不足；私有输出可能不完整，请释放空间后用新运行重试。", file=sys.stderr)
        else:
            print("本地读取或工具调用失败。请检查终端权限和本次私有日志；未输出密钥或原始异常。", file=sys.stderr)
        sys.exit(1)
    except (ValueError, subprocess.SubprocessError):
        print("本地读取或工具调用失败。请检查终端权限和本次私有日志；未输出密钥或原始异常。", file=sys.stderr)
        sys.exit(1)
