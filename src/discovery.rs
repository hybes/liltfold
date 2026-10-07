use crate::model::Media;
use std::{
    collections::HashSet,
    fs,
    path::{Path, PathBuf},
};

pub fn normalise_roots(paths: Vec<PathBuf>) -> std::io::Result<Vec<PathBuf>> {
    let mut roots = paths
        .into_iter()
        .map(fs::canonicalize)
        .collect::<Result<Vec<_>, _>>()?;
    if roots.iter().any(|r| !r.is_dir()) {
        return Err(std::io::Error::other("Choose a folder, not a file."));
    }
    roots.sort();
    roots.dedup();
    let all = roots.clone();
    roots.retain(|r| !all.iter().any(|p| p != r && r.starts_with(p)));
    Ok(roots)
}

/// Iterative traversal has no depth cap; canonical directory identities break symlink loops.
pub fn discover(
    roots: &[PathBuf],
    mut cancelled: impl FnMut() -> bool,
    mut excluded: impl FnMut(&Path) -> bool,
    mut found: impl FnMut(Media),
    mut issue: impl FnMut(String),
) {
    let mut directories = HashSet::new();
    let mut files = HashSet::new();
    let mut stack: Vec<_> = roots.iter().rev().map(|p| (p.clone(), p.clone())).collect();
    while let Some((path, root)) = stack.pop() {
        if cancelled() {
            return;
        }
        let canonical = match fs::canonicalize(&path) {
            Ok(p) => p,
            Err(e) => {
                issue(format!("{}: {e}", path.display()));
                continue;
            }
        };
        if excluded(&canonical) {
            continue;
        }
        if canonical.is_dir() {
            if !directories.insert(canonical.clone()) {
                continue;
            }
            match fs::read_dir(&canonical) {
                Ok(dir) => {
                    let mut children = Vec::new();
                    for entry in dir {
                        match entry {
                            Ok(entry) => {
                                if entry.file_name() != ".DS_Store"
                                    && !entry
                                        .file_name()
                                        .to_string_lossy()
                                        .starts_with(".liltfold-")
                                {
                                    children.push(entry.path());
                                }
                            }
                            Err(e) => issue(format!("{}: {e}", canonical.display())),
                        }
                    }
                    children.sort();
                    stack.extend(children.into_iter().rev().map(|p| (p, root.clone())));
                }
                Err(e) => issue(format!("{}: {e}", canonical.display())),
            }
        } else if canonical.is_file() && files.insert(canonical.clone()) {
            match Media::new(canonical, root, 0) {
                Ok(item) => found(item),
                Err(e) => issue(format!("{}: {e}", path.display())),
            }
        }
    }
}
