// SPDX-License-Identifier: Apache-2.0
// Derived from hum0r23/wx-cli 6dc57e69333bc6037a284bd3cec22f8043ac5e39.
// Modified for explicit target selection, verified local capture, and safe output.
/// macOS WeChat 进程内存密钥扫描器
///
/// 翻译自 find_all_keys_macos.c，使用 Mach VM API：
/// - task_for_pid: 获取目标进程的 task port（需要 root 权限）
/// - mach_vm_region: 枚举内存区域
/// - mach_vm_read: 读取内存块
///
/// 注意：
/// 1. 调用者需要 debugger 权限或用户明确授予的管理员权限
/// 2. 目标需要允许调试；仅对独立副本配置 get-task-allow
/// 3. 在内存中搜索 x'<64hex><32hex>' 格式的 SQLCipher 密钥
use anyhow::{bail, Result};
use hmac::{Hmac, Mac};
use pbkdf2::pbkdf2_hmac;
use sha2::Sha512;
use std::collections::HashSet;
use std::io::Read;
use std::path::Path;

use super::{collect_db_salts, KeyEntry};

// Mach 相关常量
const KERN_SUCCESS: i32 = 0;
const VM_PROT_READ: i32 = 1;
const VM_PROT_WRITE: i32 = 2;
const VM_REGION_BASIC_INFO_64: i32 = 9;
const CHUNK_SIZE: usize = 2 * 1024 * 1024; // 2MB
const HEX_PATTERN_LEN: usize = 96; // 64(key) + 32(salt)

// vm_region_basic_info_64 结构体
#[repr(C, packed(4))]
struct VmRegionBasicInfo64 {
    protection: i32,
    max_protection: i32,
    inheritance: u32,
    shared: u32,
    reserved: u32,
    _offset: u64,
    behavior: i32,
    user_wired_count: u16,
}

// Mach FFI 声明
#[allow(non_camel_case_types)]
type kern_return_t = i32;
#[allow(non_camel_case_types)]
type mach_port_t = u32;
#[allow(non_camel_case_types)]
type mach_vm_address_t = u64;
#[allow(non_camel_case_types)]
type mach_vm_size_t = u64;
#[allow(non_camel_case_types)]
type mach_msg_type_number_t = u32;
#[allow(non_camel_case_types)]
type vm_offset_t = usize;
#[allow(non_camel_case_types, dead_code)]
type vm_prot_t = i32;

extern "C" {
    fn mach_task_self() -> mach_port_t;
    fn task_for_pid(host: mach_port_t, pid: libc::pid_t, task: *mut mach_port_t) -> kern_return_t;
    fn mach_vm_region(
        task: mach_port_t,
        address: *mut mach_vm_address_t,
        size: *mut mach_vm_size_t,
        flavor: i32,
        info: *mut VmRegionBasicInfo64,
        info_count: *mut mach_msg_type_number_t,
        obj_name: *mut mach_port_t,
    ) -> kern_return_t;
    fn mach_vm_read(
        task: mach_port_t,
        addr: mach_vm_address_t,
        size: mach_vm_size_t,
        data: *mut vm_offset_t,
        data_cnt: *mut mach_msg_type_number_t,
    ) -> kern_return_t;
    fn mach_vm_deallocate(
        task: mach_port_t,
        addr: mach_vm_address_t,
        size: mach_vm_size_t,
    ) -> kern_return_t;
}

/// 判断字节是否是 ASCII 十六进制字符
#[inline]
fn is_hex_char(c: u8) -> bool {
    c.is_ascii_hexdigit()
}

pub fn scan_keys(
    db_dir: &Path,
    pid: libc::pid_t,
    capture_path: Option<&Path>,
) -> Result<Vec<KeyEntry>> {
    eprintln!("正在扫描用户选择的微信进程。\n");

    // 2. 获取 task port
    // SAFETY: task_for_pid 是标准 Mach API，参数合法
    let task = unsafe {
        let mut task: mach_port_t = 0;
        let kr = task_for_pid(mach_task_self(), pid, &mut task);
        if kr != KERN_SUCCESS {
            bail!(
                "微信进程拒绝调试（kr={}）；请检查临时副本是否仍允许调试，勿重签官方应用。",
                kr
            );
        }
        task
    };
    eprintln!("Got task port: {}", task);

    // 3. 收集数据库 salt 映射
    eprintln!("扫描数据库文件...");
    let db_salts = collect_db_salts(db_dir)?;
    eprintln!("找到 {} 个加密数据库", db_salts.len());
    if db_salts.is_empty() {
        bail!("未发现加密数据库，未扫描进程或写入密钥文件。");
    }

    // 4. 扫描进程内存
    eprintln!("扫描进程内存寻找密钥...");
    let mut raw_keys = scan_memory(task, &db_salts)?;
    // Optional local CommonCrypto capture; each key still needs page HMAC verification.
    if let Some(contents) = capture_path.and_then(|path| std::fs::read_to_string(path).ok()) {
        if let Ok(candidates) = serde_json::from_str::<Vec<String>>(&contents) {
            for key in candidates {
                if key.len() == 64 && key.bytes().all(|byte| byte.is_ascii_hexdigit()) {
                    raw_keys.push((key.to_lowercase(), String::new()));
                }
            }
        }
    }
    eprintln!("找到 {} 个候选密钥", raw_keys.len());

    // 5. 将密钥与数据库 salt 匹配
    let mut entries = Vec::new();
    for (key_hex, salt_hex) in &raw_keys {
        for (db_salt, db_name) in &db_salts {
            if (salt_hex.is_empty() || salt_hex == db_salt)
                && validate_candidate(&db_dir.join(db_name), key_hex)
            {
                if entries
                    .iter()
                    .any(|entry: &KeyEntry| entry.db_name == *db_name)
                {
                    break;
                }
                entries.push(KeyEntry {
                    db_name: db_name.clone(),
                    enc_key: key_hex.clone(),
                    salt: salt_hex.clone(),
                });
                break;
            }
        }
    }

    eprintln!("匹配到 {}/{} 个数据库密钥", entries.len(), db_salts.len());
    if entries.is_empty() {
        bail!("未找到可用数据库密钥；未写入空密钥文件。请确认账号已登录并加载聊天记录。");
    }
    Ok(entries)
}

/// 扫描进程内存，返回 (key_hex, salt_hex) 列表
fn scan_memory(task: mach_port_t, salts: &[(String, String)]) -> Result<Vec<(String, String)>> {
    let mut results: Vec<(String, String)> = Vec::new();
    let expression = salts
        .iter()
        .map(|(salt, _)| {
            salt.as_bytes()
                .chunks_exact(2)
                .map(|pair| format!("\\x{}", String::from_utf8_lossy(pair)))
                .collect::<String>()
        })
        .collect::<Vec<_>>()
        .join("|");
    if expression.is_empty() {
        bail!("未读取到加密数据库 salt，停止扫描。");
    }
    let matcher = regex::bytes::RegexBuilder::new(&expression)
        .unicode(false)
        .build()?;
    let ascii = regex::bytes::Regex::new(r"(?-u)[0-9a-fA-F]{64}")?;
    let mut seen_binary = HashSet::new();
    let mut addr: mach_vm_address_t = 0;
    let mut regions = 0u64;
    let mut bytes_read = 0u64;

    // Apple's vm_region.h uses #pragma pack(push, 4).
    let info_count_expected = (std::mem::size_of::<VmRegionBasicInfo64>() / 4) as u32;

    loop {
        let mut size: mach_vm_size_t = 0;
        let mut info = VmRegionBasicInfo64 {
            protection: 0,
            max_protection: 0,
            inheritance: 0,
            shared: 0,
            reserved: 0,
            _offset: 0,
            behavior: 0,
            user_wired_count: 0,
        };
        let mut info_count: mach_msg_type_number_t = info_count_expected;
        let mut obj_name: mach_port_t = 0;

        // SAFETY: mach_vm_region 枚举虚拟内存区域，所有参数合法
        let kr = unsafe {
            mach_vm_region(
                task,
                &mut addr,
                &mut size,
                VM_REGION_BASIC_INFO_64,
                &mut info,
                &mut info_count,
                &mut obj_name,
            )
        };

        if kr != KERN_SUCCESS {
            eprintln!(
                "内存区域枚举结束：kr={}，区域 {} 个，成功读取 {:.1} MiB",
                kr,
                regions,
                bytes_read as f64 / 1048576.0
            );
            if regions == 0 || bytes_read == 0 {
                bail!(
                    "已取得进程端口，但未能读取目标内存（kr={}）；未将此情况当成无密钥。",
                    kr
                );
            }
            break;
        }
        if size == 0 {
            addr = addr.saturating_add(1);
            continue;
        }

        regions += 1;
        // 只扫描可读可写区域（密钥通常存在于堆内存）
        if (info.protection & (VM_PROT_READ | VM_PROT_WRITE)) == (VM_PROT_READ | VM_PROT_WRITE) {
            bytes_read += scan_region(
                task,
                addr,
                size,
                &matcher,
                &ascii,
                &mut seen_binary,
                &mut results,
            );
        }

        addr = addr.saturating_add(size);
    }

    Ok(results)
}

/// 扫描单个内存区域，按 CHUNK_SIZE 分块读取
fn scan_region(
    task: mach_port_t,
    addr: mach_vm_address_t,
    size: mach_vm_size_t,
    matcher: &regex::bytes::Regex,
    ascii: &regex::bytes::Regex,
    seen_binary: &mut HashSet<(String, String)>,
    results: &mut Vec<(String, String)>,
) -> u64 {
    let end = addr + size;
    let mut ca = addr;
    let mut bytes_read = 0;

    while ca < end {
        let cs = std::cmp::min(end - ca, CHUNK_SIZE as u64);

        let mut data: vm_offset_t = 0;
        let mut dc: mach_msg_type_number_t = 0;

        // SAFETY: mach_vm_read 读取目标进程内存到内核缓冲区，
        // 返回的 data 指针指向通过 vm_allocate 分配的内存，
        // 必须用 mach_vm_deallocate 释放
        let kr = unsafe { mach_vm_read(task, ca, cs, &mut data, &mut dc) };

        if kr == KERN_SUCCESS {
            // SAFETY: data 是 mach_vm_read 返回的有效指针，dc 是字节数
            let buf: &[u8] = unsafe { std::slice::from_raw_parts(data as *const u8, dc as usize) };

            search_pattern(buf, results);
            collect_binary_candidates(buf, matcher, seen_binary, results);
            for found in ascii.find_iter(buf) {
                let candidate = (
                    String::from_utf8_lossy(found.as_bytes()).to_lowercase(),
                    String::new(),
                );
                if seen_binary.insert(candidate.clone()) {
                    results.push(candidate);
                }
            }
            bytes_read += dc as u64;

            // SAFETY: 释放 mach_vm_read 分配的内核内存
            unsafe {
                mach_vm_deallocate(mach_task_self(), data as u64, dc as u64);
            }
        }

        // 保留 (HEX_PATTERN_LEN + 3) 字节重叠以处理跨块边界的模式
        let overlap = HEX_PATTERN_LEN + 3;
        if cs as usize > overlap {
            ca += cs - overlap as u64;
        } else {
            ca += cs;
        }
    }
    bytes_read
}

fn to_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

// Modern WCDB can retain key material as bytes rather than the old x'hex' text.
// Adjacent memory is only a candidate: page-one HMAC must pass before saving it.
fn collect_binary_candidates(
    buf: &[u8],
    matcher: &regex::bytes::Regex,
    seen: &mut HashSet<(String, String)>,
    out: &mut Vec<(String, String)>,
) {
    for found in matcher.find_iter(buf) {
        let salt = to_hex(found.as_bytes());
        let before = (32..=512)
            .step_by(8)
            .filter_map(|offset| found.start().checked_sub(offset));
        let after = (0..=480).step_by(8).map(|offset| found.end() + offset);
        for start in before.chain(after) {
            let Some(key) = buf.get(start..start + 32) else {
                continue;
            };
            if key.iter().all(|b| *b == key[0]) {
                continue;
            }
            let candidate = (to_hex(key), salt.clone());
            if seen.insert(candidate.clone()) {
                out.push(candidate);
            }
        }
    }
}

fn validate_candidate(path: &Path, key_hex: &str) -> bool {
    if key_hex.len() != 64 {
        return false;
    }
    let mut key = [0u8; 32];
    for (index, pair) in key_hex.as_bytes().chunks_exact(2).enumerate() {
        let Ok(text) = std::str::from_utf8(pair) else {
            return false;
        };
        let Ok(byte) = u8::from_str_radix(text, 16) else {
            return false;
        };
        key[index] = byte;
    }
    let mut page = [0u8; 4096];
    let Ok(mut file) = std::fs::File::open(path) else {
        return false;
    };
    if file.read_exact(&mut page).is_err() {
        return false;
    }
    verify_page_hmac(&page, &key)
}

fn verify_page_hmac(page: &[u8; 4096], key: &[u8; 32]) -> bool {
    let mut salt = [0u8; 16];
    for (out, byte) in salt.iter_mut().zip(&page[..16]) {
        *out = *byte ^ 0x3a;
    }
    let mut mac_key = [0u8; 32];
    pbkdf2_hmac::<Sha512>(key, &salt, 2, &mut mac_key);
    let Ok(mut mac) = Hmac::<Sha512>::new_from_slice(&mac_key) else {
        return false;
    };
    // SQLCipher 4: encrypted page payload + IV + little-endian page number.
    mac.update(&page[16..4032]);
    mac.update(&1u32.to_le_bytes());
    mac.verify_slice(&page[4032..]).is_ok()
}

/// 在缓冲区中搜索 x'<96个十六进制字符>' 模式
///
/// 格式：x'<64hex(key)><32hex(salt)>'（总计 99 字节）
pub(crate) fn search_pattern(buf: &[u8], results: &mut Vec<(String, String)>) {
    let total = HEX_PATTERN_LEN + 3; // x' + 96 hex + '
    if buf.len() < total {
        return;
    }

    let mut i = 0;
    while i + total <= buf.len() {
        if buf[i] != b'x' || buf[i + 1] != b'\'' {
            i += 1;
            continue;
        }

        // 验证后续 96 字节都是十六进制字符
        let hex_start = i + 2;
        let all_hex = buf[hex_start..hex_start + HEX_PATTERN_LEN]
            .iter()
            .all(|&c| is_hex_char(c));

        if !all_hex {
            i += 1;
            continue;
        }

        // 验证结尾的单引号
        if buf[hex_start + HEX_PATTERN_LEN] != b'\'' {
            i += 1;
            continue;
        }

        // 提取 key_hex 和 salt_hex，统一转小写
        let key_hex = String::from_utf8_lossy(&buf[hex_start..hex_start + 64]).to_lowercase();
        let salt_hex = String::from_utf8_lossy(&buf[hex_start + 64..hex_start + 96]).to_lowercase();

        // 去重检查
        let is_dup = results.iter().any(|(k, s)| k == &key_hex && s == &salt_hex);
        if !is_dup {
            results.push((key_hex, salt_hex));
        }

        i += total;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn binary_candidates_and_hmac_reject_wrong_key() {
        let key = [0x71; 32];
        let mut actual_key = key;
        actual_key[7] = 0x93;
        let salt = [0x27; 16];
        let pattern = salt
            .iter()
            .map(|byte| format!("\\x{byte:02x}"))
            .collect::<String>();
        let matcher = regex::bytes::RegexBuilder::new(&pattern)
            .unicode(false)
            .build()
            .unwrap();
        let mut memory = actual_key.to_vec();
        memory.extend_from_slice(&salt);
        let mut candidates = Vec::new();
        collect_binary_candidates(&memory, &matcher, &mut HashSet::new(), &mut candidates);
        assert!(candidates.contains(&(to_hex(&actual_key), to_hex(&salt))));

        let mut page = [0x13; 4096];
        page[..16].copy_from_slice(&salt);
        let mac_salt = salt.map(|byte| byte ^ 0x3a);
        let mut mac_key = [0u8; 32];
        pbkdf2_hmac::<Sha512>(&actual_key, &mac_salt, 2, &mut mac_key);
        let mut mac = Hmac::<Sha512>::new_from_slice(&mac_key).unwrap();
        mac.update(&page[16..4032]);
        mac.update(&1u32.to_le_bytes());
        page[4032..].copy_from_slice(&mac.finalize().into_bytes());
        assert!(verify_page_hmac(&page, &actual_key));
        assert!(!verify_page_hmac(&page, &key));
        page[83] ^= 1;
        assert!(!verify_page_hmac(&page, &actual_key));
    }

    /// 构造一条合法的 x'<key><salt>' 模式字节串
    fn make_pattern(key: &[u8; 64], salt: &[u8; 32]) -> Vec<u8> {
        let mut v = vec![b'x', b'\''];
        v.extend_from_slice(key);
        v.extend_from_slice(salt);
        v.push(b'\'');
        v
    }

    #[test]
    fn test_is_hex_char_valid() {
        for c in b'0'..=b'9' {
            assert!(is_hex_char(c), "digit {}", c as char);
        }
        for c in b'a'..=b'f' {
            assert!(is_hex_char(c), "lower {}", c as char);
        }
        for c in b'A'..=b'F' {
            assert!(is_hex_char(c), "upper {}", c as char);
        }
    }

    #[test]
    fn test_is_hex_char_invalid() {
        for c in [b'g', b'G', b'x', b'\'', b' ', b'\0', b'z', b'Z'] {
            assert!(!is_hex_char(c), "expected non-hex: {}", c as char);
        }
    }

    #[test]
    fn test_search_pattern_basic() {
        let key = [b'a'; 64];
        let salt = [b'b'; 32];
        let buf = make_pattern(&key, &salt);
        let mut results = Vec::new();
        search_pattern(&buf, &mut results);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].0, "a".repeat(64));
        assert_eq!(results[0].1, "b".repeat(32));
    }

    #[test]
    fn test_search_pattern_uppercase_lowercased() {
        // 大写十六进制字符应被统一转为小写
        let key = [b'A'; 64];
        let salt = [b'B'; 32];
        let buf = make_pattern(&key, &salt);
        let mut results = Vec::new();
        search_pattern(&buf, &mut results);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].0, "a".repeat(64));
        assert_eq!(results[0].1, "b".repeat(32));
    }

    #[test]
    fn test_search_pattern_not_all_hex() {
        // 96 个十六进制字符中有一个非法字符 → 不匹配
        let mut buf = vec![b'x', b'\''];
        buf.extend_from_slice(&[b'a'; 95]);
        buf.push(b'g'); // 'g' 不是合法十六进制字符
        buf.push(b'\'');
        let mut results = Vec::new();
        search_pattern(&buf, &mut results);
        assert!(results.is_empty());
    }

    #[test]
    fn test_search_pattern_wrong_closing_quote() {
        // 结尾引号错误 → 不匹配
        let mut buf = vec![b'x', b'\''];
        buf.extend_from_slice(&[b'a'; 96]);
        buf.push(b'"'); // 应为 b'\''
        let mut results = Vec::new();
        search_pattern(&buf, &mut results);
        assert!(results.is_empty());
    }

    #[test]
    fn test_search_pattern_dedup() {
        // 相同模式出现两次 → 只保留一条
        let key = [b'1'; 64];
        let salt = [b'2'; 32];
        let pattern = make_pattern(&key, &salt);
        let mut buf = pattern.clone();
        buf.extend_from_slice(&pattern);
        let mut results = Vec::new();
        search_pattern(&buf, &mut results);
        assert_eq!(results.len(), 1);
    }

    #[test]
    fn test_search_pattern_multiple_distinct() {
        // 两个不同的合法模式 → 各自独立捕获
        let key1 = [b'a'; 64];
        let salt1 = [b'b'; 32];
        let key2 = [b'c'; 64];
        let salt2 = [b'd'; 32];
        let mut buf = make_pattern(&key1, &salt1);
        buf.extend_from_slice(&make_pattern(&key2, &salt2));
        let mut results = Vec::new();
        search_pattern(&buf, &mut results);
        assert_eq!(results.len(), 2);
        let keys: Vec<&str> = results.iter().map(|(k, _)| k.as_str()).collect();
        assert!(keys.contains(&"a".repeat(64).as_str()));
        assert!(keys.contains(&"c".repeat(64).as_str()));
    }

    #[test]
    fn test_search_pattern_embedded_in_garbage() {
        // 模式夹在垃圾字节中间，仍应找到
        let mut buf = vec![0xFFu8; 50];
        let key = [b'e'; 64];
        let salt = [b'f'; 32];
        buf.extend_from_slice(&make_pattern(&key, &salt));
        buf.extend_from_slice(&[0x00u8; 50]);
        let mut results = Vec::new();
        search_pattern(&buf, &mut results);
        assert_eq!(results.len(), 1);
    }

    #[test]
    fn test_search_pattern_too_short() {
        // 缓冲区太小，无法容纳完整模式
        let buf = [b'x', b'\'', b'a', b'b'];
        let mut results = Vec::new();
        search_pattern(&buf, &mut results);
        assert!(results.is_empty());
    }

    #[test]
    fn test_search_pattern_empty_buf() {
        let mut results = Vec::new();
        search_pattern(&[], &mut results);
        assert!(results.is_empty());
    }

    #[test]
    fn test_search_pattern_real_hex_mix() {
        // 合法的混合大小写十六进制（0-9, a-f, A-F）
        let mut key = [b'0'; 64];
        for (i, c) in b"0123456789abcdefABCDEF0123456789abcdef0123456789abcdef01234567"
            .iter()
            .enumerate()
        {
            if i < 64 {
                key[i] = *c;
            }
        }
        let salt = [b'9'; 32];
        let buf = make_pattern(&key, &salt);
        let mut results = Vec::new();
        search_pattern(&buf, &mut results);
        assert_eq!(results.len(), 1);
        // 结果应全小写
        assert!(results[0]
            .0
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit()));
    }
}
