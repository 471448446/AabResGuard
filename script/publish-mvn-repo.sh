#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION=""
BRANCH="mvn-repo"
REMOTE_BRANCH="origin/mvn-repo"
WORKTREE="/private/tmp/AabResGuard-mvn-repo"
COMMIT_MESSAGE=""

usage() {
    cat <<EOF
Usage: $0 [options]

Build the current AabResGuard Maven artifacts, copy them into a mvn-repo
worktree, update Maven metadata while preserving historical versions, and
create a local commit. The script never pushes.

Options:
  --version VERSION        Override the version from gradle/versions.gradle.
  --branch BRANCH         Local Maven repo branch. Default: mvn-repo.
  --remote-branch REF     Remote branch used when creating BRANCH. Default: origin/mvn-repo.
  --worktree PATH         Maven repo worktree path. Default: /private/tmp/AabResGuard-mvn-repo.
  -m, --message MESSAGE   Commit message. Default: Publish VERSION artifacts.
  -h, --help              Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            VERSION="$2"
            shift 2
            ;;
        --branch)
            BRANCH="$2"
            shift 2
            ;;
        --remote-branch)
            REMOTE_BRANCH="$2"
            shift 2
            ;;
        --worktree)
            WORKTREE="$2"
            shift 2
            ;;
        -m|--message)
            COMMIT_MESSAGE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

cd "$ROOT_DIR"

if [[ -z "$VERSION" ]]; then
    VERSION="$(sed -n 's/^[[:space:]]*versions\.aabresguard[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' gradle/versions.gradle | head -n 1)"
fi

if [[ -z "$VERSION" ]]; then
    echo "Could not resolve versions.aabresguard from gradle/versions.gradle." >&2
    exit 1
fi

GROUP_ID="$(sed -n 's/^[[:space:]]*GROUP_ID[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' gradle/ext.gradle | head -n 1)"
if [[ -z "$GROUP_ID" ]]; then
    echo "Could not resolve GROUP_ID from gradle/ext.gradle." >&2
    exit 1
fi

GROUP_PATH="${GROUP_ID//./\/}"
CORE_ID="aabresguard-core"
PLUGIN_ID="aabresguard-plugin"
M2_ROOT="${HOME}/.m2/repository/${GROUP_PATH}"

if [[ -z "$COMMIT_MESSAGE" ]]; then
    COMMIT_MESSAGE="Publish ${VERSION} artifacts"
fi

echo "Publishing ${GROUP_ID}:aabresguard-*:${VERSION}"

./gradlew clean :core:publishToMavenLocal --no-daemon --stacktrace

CORE_M2_DIR="${M2_ROOT}/${CORE_ID}/${VERSION}"
CORE_M2_JAR="${CORE_M2_DIR}/${CORE_ID}-${VERSION}.jar"
PLAIN_CORE_JAR="${ROOT_DIR}/core/build/libs/core.jar"

if ! jar tf "$CORE_M2_JAR" | grep -q 'com/bytedance/android/aabresguard/commands/ObfuscateBundleCommand.class'; then
    if jar tf "$PLAIN_CORE_JAR" | grep -q 'com/bytedance/android/aabresguard/commands/ObfuscateBundleCommand.class'; then
        echo "Replacing empty/broken published core jar with ${PLAIN_CORE_JAR}."
        cp "$PLAIN_CORE_JAR" "$CORE_M2_JAR"
    else
        echo "Published core jar does not contain ObfuscateBundleCommand.class." >&2
        exit 1
    fi
fi

./gradlew :plugin:publishToMavenLocal --no-daemon --stacktrace

PLUGIN_M2_DIR="${M2_ROOT}/${PLUGIN_ID}/${VERSION}"
for path in "$CORE_M2_DIR" "$PLUGIN_M2_DIR"; do
    if [[ ! -d "$path" ]]; then
        echo "Expected Maven artifact directory does not exist: $path" >&2
        exit 1
    fi
done

if [[ -e "$WORKTREE/.git" ]]; then
    CURRENT_BRANCH="$(git -C "$WORKTREE" rev-parse --abbrev-ref HEAD)"
    if [[ "$CURRENT_BRANCH" != "$BRANCH" ]]; then
        echo "Worktree $WORKTREE is on $CURRENT_BRANCH, expected $BRANCH." >&2
        exit 1
    fi
elif [[ -e "$WORKTREE" ]]; then
    echo "Worktree path exists but is not a git worktree: $WORKTREE" >&2
    exit 1
elif git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
    git worktree add "$WORKTREE" "$BRANCH"
else
    git worktree add "$WORKTREE" -b "$BRANCH" "$REMOTE_BRANCH"
fi

if [[ -n "$(git -C "$WORKTREE" status --porcelain)" ]]; then
    echo "Maven repo worktree has uncommitted changes: $WORKTREE" >&2
    git -C "$WORKTREE" status --short >&2
    exit 1
fi

mkdir -p "$WORKTREE/${GROUP_PATH}/${CORE_ID}" "$WORKTREE/${GROUP_PATH}/${PLUGIN_ID}"
cp -R "$CORE_M2_DIR" "$WORKTREE/${GROUP_PATH}/${CORE_ID}/"
cp -R "$PLUGIN_M2_DIR" "$WORKTREE/${GROUP_PATH}/${PLUGIN_ID}/"

LAST_UPDATED="$(date -u +%Y%m%d%H%M%S)"
python3 - "$WORKTREE" "$GROUP_PATH" "$GROUP_ID" "$CORE_ID" "$PLUGIN_ID" "$LAST_UPDATED" <<'PY'
import os
import re
import sys
import xml.etree.ElementTree as ET

worktree, group_path, group_id, *rest = sys.argv[1:]
artifact_ids = rest[:-1]
last_updated = rest[-1]
version_re = re.compile(r"^\d+(?:\.\d+)*(?:[-.][0-9A-Za-z]+)?$")

def version_key(value):
    parts = re.split(r"([0-9]+)", value)
    return [int(part) if part.isdigit() else part for part in parts]

for artifact_id in artifact_ids:
    artifact_dir = os.path.join(worktree, group_path, artifact_id)
    output = os.path.join(artifact_dir, "maven-metadata-local.xml")
    existing_versions = []
    existing_last_updated = None
    if os.path.exists(output):
        existing_root = ET.parse(output).getroot()
        existing_versions = [
            node.text for node in existing_root.findall("./versioning/versions/version")
            if node.text
        ]
        last_updated_node = existing_root.find("./versioning/lastUpdated")
        if last_updated_node is not None:
            existing_last_updated = last_updated_node.text

    versions = [
        name for name in os.listdir(artifact_dir)
        if os.path.isdir(os.path.join(artifact_dir, name)) and version_re.match(name)
    ]
    versions.sort(key=version_key)
    if not versions:
        raise SystemExit(f"No versions found in {artifact_dir}")

    metadata = ET.Element("metadata")
    ET.SubElement(metadata, "groupId").text = group_id
    ET.SubElement(metadata, "artifactId").text = artifact_id
    versioning = ET.SubElement(metadata, "versioning")
    ET.SubElement(versioning, "latest").text = versions[-1]
    ET.SubElement(versioning, "release").text = versions[-1]
    versions_node = ET.SubElement(versioning, "versions")
    for version in versions:
        ET.SubElement(versions_node, "version").text = version
    ET.SubElement(versioning, "lastUpdated").text = (
        existing_last_updated if existing_versions == versions and existing_last_updated else last_updated
    )

    tree = ET.ElementTree(metadata)
    ET.indent(tree, space="  ")
    tree.write(output, encoding="UTF-8", xml_declaration=True)
PY

for jar_path in \
    "$WORKTREE/${GROUP_PATH}/${CORE_ID}/${VERSION}/${CORE_ID}-${VERSION}.jar" \
    "$WORKTREE/${GROUP_PATH}/${PLUGIN_ID}/${VERSION}/${PLUGIN_ID}-${VERSION}.jar"
do
    if [[ ! -s "$jar_path" ]]; then
        echo "Jar is missing or empty: $jar_path" >&2
        exit 1
    fi
done

jar tf "$WORKTREE/${GROUP_PATH}/${CORE_ID}/${VERSION}/${CORE_ID}-${VERSION}.jar" \
    | grep -q 'com/bytedance/android/aabresguard/commands/ObfuscateBundleCommand.class'

git -C "$WORKTREE" add "${GROUP_PATH}/${CORE_ID}" "${GROUP_PATH}/${PLUGIN_ID}"

if git -C "$WORKTREE" diff --cached --quiet; then
    echo "No mvn-repo changes to commit."
    exit 0
fi

git -C "$WORKTREE" commit -m "$COMMIT_MESSAGE"

echo "Created local commit on ${BRANCH}; push manually when ready:"
echo "  git -C \"$WORKTREE\" push origin ${BRANCH}"
