// SPDX-License-Identifier: Apache-2.0
#[cfg(target_os = "macos")]
mod scanner;

#[cfg(target_os = "macos")]
use anyhow::{bail, Context, Result};
#[cfg(target_os = "macos")]
use std::{
    collections::BTreeMap,
    io::{Read, Write},
    path::{Path, PathBuf},
};

#[cfg(target_os = "macos")]
#[derive(serde::Serialize)]
pub struct KeyEntry {
    db_name: String,
    enc_key: String,
    salt: String,
}

#[cfg(target_os = "macos")]
fn collect_db_salts(root: &Path) -> Result<Vec<(String, String)>> {
    fn visit(root: &Path, dir: &Path, out: &mut Vec<(String, String)>) -> Result<()> {
        for item in std::fs::read_dir(dir).context("无法读取数据库目录，请检查终端文件权限")?
        {
            let entry = item.context("无法读取数据库目录项")?;
            let kind = entry.file_type()?;
            if kind.is_symlink() {
                continue;
            }
            let path = entry.path();
            if kind.is_dir() {
                visit(root, &path, out)?;
            } else if kind.is_file() && path.extension().is_some_and(|ext| ext == "db") {
                let mut header = [0u8; 16];
                std::fs::File::open(&path)
                    .context("无法读取数据库")?
                    .read_exact(&mut header)?;
                if &header[..15] != b"SQLite format 3" {
                    let salt = header.iter().map(|b| format!("{b:02x}")).collect();
                    let relative = path
                        .strip_prefix(root)?
                        .to_str()
                        .context("数据库路径编码无效")?
                        .to_owned();
                    out.push((salt, relative));
                }
            }
        }
        Ok(())
    }
    let mut result = Vec::new();
    visit(root, root, &mut result)?;
    Ok(result)
}

#[cfg(target_os = "macos")]
fn run() -> Result<()> {
    use std::os::unix::fs::OpenOptionsExt;
    unsafe {
        libc::umask(0o077);
    }
    let mut args = std::env::args().skip(1);
    let mut options = BTreeMap::new();
    while let Some(name) = args.next() {
        if !["--pid", "--db-dir", "--output", "--candidates"].contains(&name.as_str()) {
            bail!("用法：wechat-key-extractor --pid PID --db-dir DIR --output FILE [--candidates FILE]");
        }
        let value = args.next().context("缺少参数值")?;
        if options.insert(name, value).is_some() {
            bail!("重复参数");
        }
    }
    let pid: libc::pid_t = options.get("--pid").context("缺少进程参数")?.parse()?;
    if pid <= 0 {
        bail!("微信进程参数无效");
    }
    let process = std::process::Command::new("/bin/ps")
        .args(["-p", &pid.to_string(), "-o", "comm="])
        .output()?;
    if !process.status.success()
        || !String::from_utf8_lossy(&process.stdout)
            .trim()
            .ends_with("/Contents/MacOS/WeChat")
    {
        bail!("所选进程不是微信主进程");
    }
    let source = PathBuf::from(options.get("--db-dir").context("缺少数据库目录")?);
    if !source.is_absolute()
        || source.symlink_metadata()?.file_type().is_symlink()
        || !source.is_dir()
    {
        bail!("数据库目录必须是本地绝对路径，且不能为符号链接");
    }
    let output = PathBuf::from(options.get("--output").context("缺少输出文件")?);
    let captured = options.get("--candidates").map(PathBuf::from);
    let entries = scanner::scan_keys(&source, pid, captured.as_deref())?;
    let map: BTreeMap<_, _> = entries
        .into_iter()
        .map(|entry| (entry.db_name, serde_json::json!({"enc_key": entry.enc_key})))
        .collect();
    // No overwrite, no symlink following, and private mode from creation onward.
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(output)
        .context("输出已存在或无法创建，未覆盖")?;
    file.write_all(&serde_json::to_vec_pretty(&map)?)?;
    file.sync_all()?;
    println!("已保存 {} 个通过第一页 HMAC 校验的数据库密钥。", map.len());
    Ok(())
}

#[cfg(target_os = "macos")]
fn main() {
    if let Err(error) = run() {
        // Only our contextual message, never an underlying path or key value.
        eprintln!("{}", error);
        std::process::exit(1);
    }
}

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("密钥获取模块仅支持 macOS。");
    std::process::exit(2);
}
