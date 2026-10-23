"""把本地 HEAD 与远端 main 的差异通过 GitHub API 同步上去。

用法：
    GH_PAT=<token> python3 tools/sync-to-github.py
    # 可选：GH_REPO=owner/name、REPO_ROOT=/path/to/repo

为什么需要它：开发沙箱到 github.com:443 不通，`git push` 无法用，
只能走 REST API 手动建 blob/tree/commit 再移动 ref。

为什么不按提交历史逐个重建：脚本每次都用 API 重建提交，得到的 SHA 与本地不同，
祖先关系会断，`git rev-list remote..HEAD` 直接报错。所以改成按**内容**比对：
文件集合或 blob 不一样的就传，最后合成一个提交推上去。
代价是远端历史是"快照式"的，不是本地逐条提交的镜像——够用，因为
GitHub 那边只用来备份与浏览，真正的历史在本地仓库。
"""
import base64
import json
import os
import subprocess
import time
import urllib.error
import urllib.request

PAT = os.environ["GH_PAT"]
REPO = os.environ.get("GH_REPO", "emfox/famdaily")
BASE = f"https://api.github.com/repos/{REPO}"
ROOT = os.environ.get("REPO_ROOT", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HDR = {
    "Authorization": f"Bearer {PAT}",
    "Accept": "application/vnd.github+json",
    "Content-Type": "application/json",
    "User-Agent": "famdaily-sync",
}


def call(url, method="GET", body=None, retries=3):
    data = json.dumps(body).encode() if body is not None else None
    last = None
    for attempt in range(retries):
        r = urllib.request.Request(url, data=data, method=method)
        for k, v in HDR.items():
            r.add_header(k, v)
        try:
            with urllib.request.urlopen(r, timeout=30) as resp:
                raw = resp.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            msg = e.read().decode(errors="replace")
            if e.code < 500 and e.code != 429:
                raise SystemExit(f"HTTP {e.code} {method} {url}\n{msg}")
            last = f"HTTP {e.code}: {msg}"
        except Exception as e:
            last = repr(e)
        time.sleep(1.5 * (attempt + 1))
    raise SystemExit(f"重试仍失败 {method} {url}: {last}")


def git(*args):
    return subprocess.run(
        ["git", "-C", ROOT, *args], capture_output=True, check=True
    ).stdout


def local_entries():
    """本地 HEAD 的全部 blob：path -> (mode, git blob sha)。"""
    out = git("ls-tree", "-r", "-z", "HEAD")
    entries = {}
    for rec in out.decode().split("\0"):
        if not rec.strip():
            continue
        meta, path = rec.split("\t", 1)
        mode, typ, sha = meta.split()
        if typ == "blob":
            entries[path] = (mode, sha)
    return entries


def remote_entries(commit_sha):
    """远端当前树的全部 blob。用 GitHub 的 tree API，拿 git blob sha 直接比。"""
    data = call(f"{BASE}/git/trees/{commit_sha}?recursive=1")
    return {
        e["path"]: (e["mode"], e["sha"])
        for e in data["tree"]
        if e["type"] == "blob"
    }


def main():
    head = call(f"{BASE}/git/ref/heads/main")["object"]["sha"]
    print("远端 main:", head[:8])

    local = local_entries()
    remote = remote_entries(head)
    print(f"本地 {len(local)} 个文件，远端 {len(remote)} 个")

    changed = [p for p, v in local.items() if remote.get(p) != v]
    removed = [p for p in remote if p not in local]
    if not changed and not removed:
        print("已同步，无需推送")
        return
    print(f"需更新 {len(changed)} 个，需删除 {len(removed)} 个")

    items = []
    for i, path in enumerate(sorted(changed), 1):
        mode, sha = local[path]
        content = git("cat-file", "blob", sha)
        blob = call(
            f"{BASE}/git/blobs",
            "POST",
            {
                "content": base64.b64encode(content).decode(),
                "encoding": "base64",
            },
        )
        items.append(
            {"path": path, "mode": mode, "type": "blob", "sha": blob["sha"]}
        )
        if i % 10 == 0 or i == len(changed):
            print(f"  ...{i}/{len(changed)}")

    # 删除项：把 path 指向 null 即可从 tree 里摘掉。
    for path in removed:
        items.append({"path": path, "mode": "100644", "type": "blob", "sha": None})

    # 用 base_tree 做底，只覆盖变化的文件；删除用 sha=None 表达。
    base_tree = call(f"{BASE}/git/commits/{head}")["tree"]["sha"]
    tree = call(
        f"{BASE}/git/trees",
        "POST",
        {"base_tree": base_tree, "tree": items},
    )
    print("tree:", tree["sha"][:8])

    msg = git("log", "-1", "--format=%B", "HEAD").decode().strip()
    created = call(
        f"{BASE}/git/commits",
        "POST",
        {"message": msg, "tree": tree["sha"], "parents": [head]},
    )
    print("commit:", created["sha"][:8])

    upd = call(
        f"{BASE}/git/refs/heads/main", "PATCH", {"sha": created["sha"], "force": False}
    )
    print("ref ->", upd["object"]["sha"][:8])

    after = remote_entries(upd["object"]["sha"])
    missing = [p for p, v in local.items() if after.get(p) != v]
    print(f"远端文件数：{len(after)}  不一致：{missing or '无'}")


if __name__ == "__main__":
    main()
