use crate::model::{Media, Stamp};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs::File,
    io::{self, Read, Seek, SeekFrom},
    path::Path,
};

fn interrupted() -> io::Error {
    io::Error::new(io::ErrorKind::Interrupted, "Cancelled")
}
pub fn hash_file(path: &Path, mut cancelled: impl FnMut() -> bool) -> io::Result<String> {
    let before = Stamp::read(path)?;
    let mut file = File::open(path)?;
    let mut hash = Sha256::new();
    let mut buffer = [0u8; 128 * 1024];
    loop {
        if cancelled() {
            return Err(interrupted());
        }
        let n = file.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        hash.update(&buffer[..n]);
    }
    if before != Stamp::read(path)? {
        return Err(io::Error::other("File changed during duplicate check"));
    }
    Ok(format!("{:x}", hash.finalize()))
}
fn sample(path: &Path) -> io::Result<Vec<u8>> {
    let mut f = File::open(path)?;
    let len = f.metadata()?.len();
    let mut data = vec![0; 65536];
    let n = f.read(&mut data)?;
    data.truncate(n);
    if len > 65536 {
        f.seek(SeekFrom::Start(len.saturating_sub(65536)))?;
        f.read_to_end(&mut data)?;
    }
    Ok(Sha256::digest(data).to_vec())
}
fn equal(a: &Path, b: &Path, cancelled: &mut impl FnMut() -> bool) -> io::Result<bool> {
    let (mut a, mut b) = (File::open(a)?, File::open(b)?);
    let (mut x, mut y) = ([0u8; 128 * 1024], [0u8; 128 * 1024]);
    loop {
        if cancelled() {
            return Err(interrupted());
        }
        let n = a.read(&mut x)?;
        let mut read = 0;
        while read < n {
            let m = b.read(&mut y[read..n])?;
            if m == 0 {
                return Ok(false);
            }
            read += m;
        }
        if x[..n] != y[..n] {
            return Ok(false);
        }
        if n == 0 {
            return Ok(b.read(&mut y[..1])? == 0);
        }
    }
}

/// Size and a small sample only narrow candidates. SHA-256 and a byte comparison establish equality.
pub fn groups(
    items: &[Media],
    mut cancelled: impl FnMut() -> bool,
    mut progress: impl FnMut(usize, usize),
) -> io::Result<Vec<Vec<usize>>> {
    let mut sizes: BTreeMap<u64, Vec<&Media>> = BTreeMap::new();
    for m in items {
        sizes.entry(m.size).or_default().push(m);
    }
    let candidates: Vec<_> = sizes
        .into_values()
        .filter(|g| g.len() > 1)
        .flatten()
        .collect();
    let total = candidates.len();
    let mut sampled: BTreeMap<(u64, Vec<u8>), Vec<&Media>> = BTreeMap::new();
    for (i, m) in candidates.iter().enumerate() {
        if cancelled() {
            return Err(interrupted());
        }
        if Stamp::read(&m.path)? != m.stamp {
            return Err(io::Error::other(format!(
                "{} changed; refresh the collection",
                m.name
            )));
        }
        sampled
            .entry((m.size, sample(&m.path)?))
            .or_default()
            .push(m);
        progress(i + 1, total * 2);
    }
    let mut result = vec![];
    let mut done = total;
    for group in sampled.into_values().filter(|g| g.len() > 1) {
        let mut hashes: BTreeMap<String, Vec<&Media>> = BTreeMap::new();
        for m in group {
            let hash = hash_file(&m.path, &mut cancelled)?;
            hashes.entry(hash).or_default().push(m);
            done += 1;
            progress(done, total * 2);
        }
        for mut same in hashes.into_values().filter(|g| g.len() > 1) {
            same.sort_by(|a, b| a.path.cmp(&b.path));
            let first = same[0];
            let mut verified = vec![first.id];
            for m in &same[1..] {
                if equal(&first.path, &m.path, &mut cancelled)?
                    && Stamp::read(&m.path)? == m.stamp
                    && Stamp::read(&first.path)? == first.stamp
                {
                    verified.push(m.id);
                } else {
                    return Err(io::Error::other(
                        "Files changed during duplicate verification",
                    ));
                }
            }
            result.push(verified);
        }
    }
    progress(total * 2, total * 2);
    Ok(result)
}
