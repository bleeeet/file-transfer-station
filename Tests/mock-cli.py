#!/usr/bin/env python3
"""Local integration fixture: never contacts Baidu or reads account credentials."""
import sys, pathlib, shutil, time, os

root = pathlib.Path('/tmp/baidu-transfer-mock-cloud')
root.mkdir(exist_ok=True)
args = sys.argv[1:]
def target(p):
    p = p.replace('\\[', '[').replace('\\]', ']').replace('\\?', '?').replace('\\*', '*')
    return root / p.lstrip('/')
if not args:
    for line in sys.stdin:
        if line.startswith('login '):
            if 'BDUSS=fixture-valid;' in line:
                print('百度帐号登录成功: 测试账户', flush=True)
                (pathlib.Path(os.environ['BAIDUPCS_GO_CONFIG_DIR']) / 'pcs_config.json').write_text('{}')
            else:
                print('凭据导入失败', flush=True)
        if line.startswith('quit'): break
    sys.exit(0)
cmd = args[0]
if cmd == 'who': print('当前帐号 uid: 123, 用户名: 测试账户, 性别: , 年龄: 0.0')
elif cmd == 'mkdir': target(args[1]).mkdir(parents=True, exist_ok=True); print('创建目录成功')
elif cmd == 'ls':
    p = target(args[1])
    if not p.exists(): print('文件不存在'); sys.exit(1)
    items = sorted(p.iterdir())
    print('当前目录: ' + args[1] + '\n----\n # 文件大小 修改日期 文件(目录)')
    for i, x in enumerate(items):
        print(f'{i}  {"-" if x.is_dir() else str(x.stat().st_size)+" B"}  2026-10-13 12:00:00  {x.name}{"/" if x.is_dir() else ""}')
    print(f'文件总数: {sum(x.is_file() for x in items)}, 目录总数: {sum(x.is_dir() for x in items)}\n----')
elif cmd == 'upload':
    files = args[3:-1]; dest = target(args[-1]); dest.mkdir(parents=True, exist_ok=True)
    for name in files:
        p = pathlib.Path(name)
        # Like the real CLI, a missing remote folder fails the files inside it.
        missing = [d for d in ([p] + [x for x in p.rglob('*') if x.is_dir()] if p.is_dir() else []) if not (dest / d.relative_to(p.parent)).is_dir()]
        if missing: print('[1] 获取文件列表错误, 代码: -9, 消息: 文件不存在\n上传结束, 总大小: 0B\n以下文件上传失败: \n  1  ' + name, flush=True); sys.exit(0)
        (shutil.copytree(p, dest / p.name, dirs_exist_ok=True) if p.is_dir() else shutil.copy2(p, dest / p.name))
    print('[1] ↑ 512B/1.00KB 1.00KB/s in 1s, left 1s ............', flush=True); time.sleep(.2); print('上传结束, 总大小: 1 KB')
elif cmd == 'mv':
    for name in args[1:-1]: shutil.move(str(target(name)), str(target(args[-1])))
    print('操作成功, 以下文件/目录移动成功:')
elif cmd == 'rm':
    p = target(args[1]); p.rmdir(); print('删除成功')
elif cmd == 'download':
    dest = pathlib.Path(args[2]); p = target(args[3]); dest.mkdir(parents=True, exist_ok=True)
    (shutil.copytree if p.is_dir() else shutil.copy2)(p, dest / p.name)
    print('[1] ↓ 512B/1.00KB 1.00KB/s in 1s, left 1s ............', flush=True); time.sleep(.2); print('下载结束, 数据总量: 1 KB')
elif cmd == 'login':
    print('请输入百度用户名(手机号/邮箱/用户名), 回车键提交 > ', flush=True)
    sys.stdin.readline()
    print('请输入密码 > ', flush=True); sys.stdin.readline()
    print('请输入接收到的验证码 > ', flush=True); sys.stdin.readline(); print('登录成功')
