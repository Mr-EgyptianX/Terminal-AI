#!/system/bin/sh

APP_NAME="Termux AI"
VERSION="3.0"

ERROR_LOG="$HOME/termux_ai_error.log"
TEMP_DIR="$HOME/.termux_ai_tmp"

mkdir -p "$TEMP_DIR"

clear_screen() {
    clear 2>/dev/null || printf '\033c'
}

pause_screen() {
    printf "\nPress ENTER to continue..."
    read dummy
}

show_header() {
    clear_screen
    printf "\n====================================\n"
    printf "          %s v%s\n" "$APP_NAME" "$VERSION"
    printf "====================================\n\n"
}

print_ok() {
    printf "[OK] %s\n" "$1"
}

print_error() {
    printf "[ERROR] %s\n" "$1"
}

print_info() {
    printf "[INFO] %s\n" "$1"
}

bootstrap_files() {
    ADVANCED_AI_TARGET="advanced_ai.py"
    ADVANCED_DB_TARGET="advanced_database.db"

    if [ ! -f "$ADVANCED_AI_TARGET" ]; then
        cat > "$ADVANCED_AI_TARGET" << 'ADVANCED_AI_PY_EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Advanced AI Engine v4.0
- Multi-layer command correction
- Context-aware suggestions
- Learning from usage
- Multiple ranked suggestions
"""

import difflib
import json
import os
import re
import shlex
import subprocess
import shutil
import sys
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple


# ============================================================
# CONFIGURATION
# ============================================================

DATABASE_FILE = "advanced_database.db"
LEARNING_FILE = ".ai_learning.json"
HISTORY_FILE = ".ai_history.json"
MAX_HISTORY = 200
MAX_SUGGESTIONS = 5

# Termux-specific command preferences
TERMUX_PREFERRED = {
    "install": "pkg",
    "update": "pkg",
    "search": "pkg",
    "python": "python3",
    "python2": "python3",
}


# ============================================================
# TYPES
# ============================================================

Record = Dict[str, str]


# ============================================================
# LAYER 1: SMART PREPROCESSING
# ============================================================

# Common abbreviations users type
ABBREVIATIONS = {
    "ll": "ls -la",
    "la": "ls -A",
    "l": "ls",
    "grep": "grep",
    "ps": "ps",
    "gd": "git diff",
    "gs": "git status",
    "gc": "git commit",
    "ga": "git add",
    "gp": "git push",
    "gl": "git log",
    "dc": "docker compose",
    "dk": "docker",
    "k": "kubectl",
    "tf": "terraform",
}

# Common typos (keyboard-adjacent)
COMMON_TYPOS = {
    "lst": "ls",
    "lss": "ls",
    "laa": "ls",
    "catt": "cat",
    "mkdri": "mkdir",
    "tuch": "touch",
    "toch": "touch",
    "grpe": "grep",
    "gerp": "grep",
    "gti": "git",
    "pyhton": "python",
    "pyton": "python",
    "pytohn": "python",
    "ecoh": "echo",
    "ehco": "echo",
    "pwe": "pwd",
}


def expand_abbreviations(text: str) -> str:
    """Expand common abbreviations before analysis."""
    parts = text.strip().split(maxsplit=1)
    if not parts:
        return text
    first = parts[0].lower()
    if first in ABBREVIATIONS:
        rest = parts[1] if len(parts) > 1 else ""
        return (ABBREVIATIONS[first] + " " + rest).strip()
    return text


def fix_common_typos(text: str) -> str:
    """Fix very common typos in the first token."""
    parts = text.strip().split(maxsplit=1)
    if not parts:
        return text
    first = parts[0].lower()
    if first in COMMON_TYPOS:
        rest = parts[1] if len(parts) > 1 else ""
        return (COMMON_TYPOS[first] + " " + rest).strip()
    return text


def normalize_text(text: str, keep_dash: bool = True) -> str:
    """
    Normalize text for comparison.
    keep_dash=True preserves hyphens so apt-get != apt get
    """
    text = text.lower().strip()

    if keep_dash:
        text = re.sub(r"[_/\\]+", " ", text)
    else:
        text = re.sub(r"[_/\\-]+", " ", text)

    text = re.sub(r"\s+", " ", text)
    return text

# ============================================================
# LAYER 2: FUZZY MATCHING
# ============================================================

def text_similarity(first: str, second: str) -> float:
    """Sequence-based similarity."""
    first = normalize_text(first)
    second = normalize_text(second)

    if not first or not second:
        return 0.0

    return difflib.SequenceMatcher(None, first, second).ratio()


def token_overlap(first: str, second: str) -> float:
    """Jaccard similarity on tokens."""
    first_words = set(re.findall(r"[A-Za-z0-9_+-]+", normalize_text(first)))
    second_words = set(re.findall(r"[A-Za-z0-9_+-]+", normalize_text(second)))

    if not first_words or not second_words:
        return 0.0

    intersection = len(first_words & second_words)
    union = len(first_words | second_words)
    return intersection / union if union else 0.0


def partial_ratio(first: str, second: str) -> float:
    """
    Find best matching substring.
    Useful when user types part of a command.
    """
    first = normalize_text(first)
    second = normalize_text(second)

    if not first or not second:
        return 0.0

    if len(first) > len(second):
        first, second = second, first

    best = 0.0
    window = len(first)

    for i in range(len(second) - window + 1):
        chunk = second[i:i + window]
        ratio = difflib.SequenceMatcher(None, first, chunk).ratio()
        if ratio > best:
            best = ratio

    return best

# ============================================================
# LAYER 3: PHONETIC MATCHING
# ============================================================

def phonetic_key(word: str) -> str:
    """
    Simplified Soundex-like algorithm.
    Handles common phonetic typos: gti -> git
    """
    word = word.lower()
    if not word:
        return ""

    # Keep first letter
    first = word[0]

    # Replace phonetic equivalents
    replacements = [
        ("ph", "f"),
        ("ck", "k"),
        ("qu", "k"),
        ("x", "ks"),
        ("wh", "w"),
        ("gh", "g"),
        ("sh", "s"),
        ("ch", "c"),
        ("th", "t"),
    ]

    body = word[1:]
    for old, new in replacements:
        body = body.replace(old, new)

    # Remove vowels (except first) and duplicate consonants
    result = first
    prev = first
    for ch in body:
        if ch in "aeiou":
            continue
        if ch != prev:
            result += ch
            prev = ch

    return result[:8]


def phonetic_similarity(first: str, second: str) -> float:
    """Compare using phonetic keys."""
    a = phonetic_key(first)
    b = phonetic_key(second)

    if not a or not b:
        return 0.0

    return difflib.SequenceMatcher(None, a, b).ratio()

# ============================================================
# LAYER 4: SEMANTIC SCORING (Value Kinds)
# ============================================================

def value_kind(token: str) -> str:
    """Guess the type of a value supplied by the user."""
    token = token.strip()

    if not token:
        return "empty"

    # Operators
    if token in ("&&", "||", "|", ";", "&"):
        return "operator"

    # Redirects
    if token in (">", ">>", "<", "2>", "2>>", "&>"):
        return "redirect"

    # Options
    if token.startswith("-") and token != "-":
        return "option"

    # Numbers
    if re.fullmatch(r"\d+(?:\.\d+)?", token):
        return "number"

    # URLs
    if re.match(r"^https?://", token):
        return "url"

    # IP addresses
    if re.fullmatch(r"\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(:\d+)?", token):
        return "ip"

    # Ports (number after :)
    if re.fullmatch(r":\d+", token):
        return "port"

    # Time durations
    if re.fullmatch(r"\d+[smhdw]", token):
        return "time"

    # Regex patterns (contain special chars)
    if any(c in token for c in "[](){}*+?^$\\"):
        return "regex"

    # Directory
    if token.endswith("/") or (
        "/" in token and "." not in token.rsplit("/", 1)[-1]
    ):
        return "directory"

    # File with extension
    if re.search(r"\.[A-Za-z0-9_-]+$", token):
        return "file"

    # Path
    if "/" in token:
        return "path"

    return "word"


def pattern_kind(token: str) -> str:
    """Guess the expected value type from a syntax token."""
    token = token.strip().lower()
    token = token.strip("<>()[]{}")
    token = token.replace("...", "")

    # Options
    if token.startswith("-") or any(w in token for w in ("option", "flag", "flags")):
        return "option"

    # Directory
    if any(w in token for w in ("directory", "folder", "dir")):
        return "directory"

    # Path
    if "path" in token:
        return "path"

    # URL
    if any(w in token for w in ("url", "uri", "link")):
        return "url"

    # IP
    if any(w in token for w in ("ip", "host", "hostname")):
        return "ip"

    # Port
    if "port" in token:
        return "port"

    # Regex
    if any(w in token for w in ("pattern", "regex", "expression")):
        return "regex"

    # Time
    if any(w in token for w in ("time", "duration", "interval", "timeout")):
        return "time"

    # File
    if any(w in token for w in ("file", "filename", "script", "archive", "input", "output")):
        return "file"

    # Number
    if any(w in token for w in ("number", "count", "pid", "size", "n")):
        return "number"

    # Operator
    if token in ("&&", "||", "|", ";", "&"):
        return "operator"

    return "word"


def kind_similarity(user_kind: str, syntax_kind: str) -> float:
    """Compare kind of user value with expected kind."""
    if user_kind == syntax_kind:
        return 1.0

    # Related kinds with weights
    related = {
        frozenset(("file", "path")): 0.90,
        frozenset(("directory", "path")): 0.85,
        frozenset(("word", "file")): 0.60,
        frozenset(("word", "path")): 0.60,
        frozenset(("word", "directory")): 0.55,
        frozenset(("number", "port")): 0.85,
        frozenset(("word", "regex")): 0.50,
        frozenset(("word", "url")): 0.50,
        frozenset(("word", "ip")): 0.50,
        frozenset(("number", "time")): 0.70,
        frozenset(("option", "word")): 0.30,
    }

    return related.get(frozenset((user_kind, syntax_kind)), 0.0)


# ============================================================
# LAYER 5: STRUCTURE SIMILARITY (DP)
# ============================================================

def parse_syntax_tokens(syntax: str) -> List[str]:
    """Parse command syntax and remove the command name."""
    tokens = split_input(syntax)
    if tokens is None:
        tokens = syntax.split()
    if len(tokens) <= 1:
        return []
    return tokens[1:]


def structure_similarity(user_parts: List[str], syntax: str) -> float:
    """
    Compare structural shape via dynamic programming.
    Now with adaptive weights.
    """
    user_kinds = [value_kind(t) for t in user_parts[1:]]
    syntax_kinds = [pattern_kind(t) for t in parse_syntax_tokens(syntax)]

    user_count = len(user_kinds)
    syntax_count = len(syntax_kinds)

    if syntax_count == 0:
        return 1.0 if user_count == 0 else 0.0

    # DP table
    table = [[0.0] * (syntax_count + 1) for _ in range(user_count + 1)]

    # Adaptive penalties
    delete_penalty = 0.30
    insert_penalty = 0.20

    for i in range(1, user_count + 1):
        table[i][0] = max(0.0, table[i - 1][0] - delete_penalty)

    for j in range(1, syntax_count + 1):
        table[0][j] = max(0.0, table[0][j - 1] - insert_penalty)

    for i in range(1, user_count + 1):
        for j in range(1, syntax_count + 1):
            match_score = table[i - 1][j - 1] + kind_similarity(
                user_kinds[i - 1], syntax_kinds[j - 1]
            )
            delete_score = table[i - 1][j] - delete_penalty
            insert_score = table[i][j - 1] - insert_penalty
            table[i][j] = max(0.0, match_score, delete_score, insert_score)

    maximum_length = max(user_count, syntax_count)
    if maximum_length == 0:
        return 1.0

    return max(0.0, min(1.0, table[user_count][syntax_count] / maximum_length))


# ============================================================
# LAYER 6: RECORD SCORING
# ============================================================

def split_input(text: str) -> Optional[List[str]]:
    """Safely split shell-like input."""
    try:
        return shlex.split(text)
    except ValueError:
        return None


def record_text_score(user_input: str, record: Record) -> float:
    """Compare user input with all record fields."""
    candidates = [
        record.get("name", ""),
        record.get("syntax", ""),
        record.get("description", ""),
        record.get("example", ""),
        record.get("category", ""),
    ]

    scores: List[float] = []
    for candidate in candidates:
        if not candidate:
            continue
        scores.append(text_similarity(user_input, candidate))
        scores.append(token_overlap(user_input, candidate))
        scores.append(partial_ratio(user_input, candidate))

    return max(scores) if scores else 0.0


# ============================================================
# LAYER 7: CONTEXT AWARENESS
# ============================================================

def detect_context(user_input: str) -> str:
    """
    Detect the context of the command.
    Returns: package, git, file, network, system, unknown
    """
    text = user_input.lower()

    if any(w in text for w in ("install", "update", "upgrade", "remove", "search", "pkg", "apt")):
        return "package"
    if any(w in text for w in ("git", "commit", "push", "pull", "merge", "branch", "clone")):
        return "git"
    if any(w in text for w in ("cat", "nano", "vim", "less", "head", "tail", "touch", "rm", "cp", "mv")):
        return "file"
    if any(w in text for w in ("curl", "wget", "ping", "ssh", "scp", "http", "https")):
        return "network"
    if any(w in text for w in ("ps", "kill", "top", "free", "df", "du", "uname", "whoami")):
        return "system"

    return "unknown"


def context_boost(record: Record, context: str) -> float:
    """
    Boost score based on context match.
    Returns multiplier between 0.9 and 1.15
    """
    if context == "unknown":
        return 1.0

    record_category = record.get("category", "").lower()
    record_name = record.get("name", "").lower()

    if context == "package" and record_category in ("package", "termux"):
        return 1.15
    if context == "git" and "git" in record_name:
        return 1.15
    if context == "file" and record_category in ("filesystem", "text"):
        return 1.10
    if context == "network" and record_category == "network":
        return 1.15
    if context == "system" and record_category in ("system", "process"):
        return 1.10

    return 1.0


# ============================================================
# LAYER 8: LEARNING FROM USAGE
# ============================================================

class LearningStore:
    """Persistent learning store for usage statistics."""

    def __init__(self, path: str = LEARNING_FILE):
        self.path = path
        self.data = self._load()

    def _load(self) -> Dict:
        if not os.path.exists(self.path):
            return {"commands": {}, "suggestions": {}, "corrections": {}}
        try:
            with open(self.path, "r", encoding="utf-8") as f:
                return json.load(f)
        except (json.JSONDecodeError, OSError):
            return {"commands": {}, "suggestions": {}, "corrections": {}}

    def save(self) -> None:
        try:
            with open(self.path, "w", encoding="utf-8") as f:
                json.dump(self.data, f, indent=2, ensure_ascii=False)
        except OSError:
            pass

    def record_command(self, command: str) -> None:
        """Record a successfully used command."""
        self.data.setdefault("commands", {})
        self.data["commands"][command] = self.data["commands"].get(command, 0) + 1
        self.save()

    def record_correction(self, wrong: str, correct: str) -> None:
        """Record a correction the user accepted."""
        self.data.setdefault("corrections", {})
        self.data["corrections"][wrong.lower()] = correct
        self.save()

    def get_frequency_boost(self, command: str) -> float:
        """Get boost factor based on usage frequency."""
        count = self.data.get("commands", {}).get(command, 0)
        # Logarithmic boost: 1.0 + log(1+count)/10
        import math
        return 1.0 + math.log1p(count) / 10.0

    def get_known_correction(self, command: str) -> Optional[str]:
        """Check if we've seen this exact error before."""
        return self.data.get("corrections", {}).get(command.lower())


# ============================================================
# DATABASE LOADING
# ============================================================

def load_command_records(database_file: str = DATABASE_FILE) -> List[Record]:
    """Load complete command records from the database."""
    records: List[Record] = []

    try:
        with open(database_file, "r", encoding="utf-8") as file:
            for raw_line in file:
                line = raw_line.strip()

                if not line or line.startswith("#"):
                    continue

                parts = line.split("|", 8)

                if len(parts) < 9 or parts[0].strip() != "C":
                    continue

                record = {
                    "id": parts[1].strip(),
                    "name": parts[2].strip(),
                    "type": parts[3].strip(),
                    "category": parts[4].strip(),
                    "syntax": parts[5].strip(),
                    "description": parts[6].strip(),
                    "example": parts[7].strip(),
                    "package": parts[8].strip(),
                }

                if not record["name"]:
                    continue

                records.append(record)

    except FileNotFoundError:
        print(f"Database file not found: {database_file}")
        return []
    except OSError as error:
        print(f"Database error: {error}")
        return []

    return records


def build_index(records: List[Record]) -> Dict[str, Record]:
    """Build a name -> record index for fast lookup."""
    index = {}
    for record in records:
        name = record["name"].lower()
        index[name] = record
    return index


# ============================================================
# RANKING ENGINE
# ============================================================

def rank_records(
    user_input: str,
    records: List[Record],
    learning: Optional[LearningStore] = None,
) -> List[Tuple[float, Record]]:
    """
    Rank all database commands using multiple analysis layers.
    """
    parts = split_input(user_input)
    if not parts:
        return []

    typed_command = parts[0].lower()
    context = detect_context(user_input)

    ranked: List[Tuple[float, Record]] = []

    for record in records:
        command_name = record["name"].lower()

        # Layer 2: fuzzy
        name_score = text_similarity(typed_command, command_name)
        partial_score = partial_ratio(typed_command, command_name)

        # Layer 3: phonetic
        phonetic_score = phonetic_similarity(typed_command, command_name)

        # Exact match
        if command_name == typed_command:
            name_score = 1.0

        # Layer 5: structure
        structure_score = structure_similarity(parts, record["syntax"])

        # Layer 6: full text
        full_text_score = record_text_score(user_input, record)

        # Layer 7: context
        ctx_boost = context_boost(record, context)

        # Layer 8: learning
        freq_boost = 1.0
        if learning:
            freq_boost = learning.get_frequency_boost(record["name"])

        # Weighted combination
        if name_score >= 0.80:
            final_score = (
                name_score * 0.50
                + partial_score * 0.10
                + phonetic_score * 0.05
                + structure_score * 0.20
                + full_text_score * 0.15
            )
        else:
            final_score = (
                name_score * 0.30
                + partial_score * 0.10
                + phonetic_score * 0.10
                + structure_score * 0.30
                + full_text_score * 0.20
            )

        final_score *= ctx_boost
        final_score *= freq_boost

        ranked.append((final_score, record))

    ranked.sort(key=lambda item: item[0], reverse=True)
    return ranked


def build_corrected_command(record: Record, user_parts: List[str]) -> str:
    """Replace only the command name. Keep all user arguments untouched."""
    corrected_parts = [record["name"]] + user_parts[1:]
    return " ".join(shlex.quote(part) for part in corrected_parts)


def suggest_commands(
    user_input: str,
    records: List[Record],
    learning: Optional[LearningStore] = None,
    max_results: int = MAX_SUGGESTIONS,
) -> List[Tuple[float, str, Record]]:
    """
    Return top N suggestions with confidence scores.
    """
    parts = split_input(user_input)
    if not parts or not records:
        return []

    typed_command = parts[0].lower()
    ranked = rank_records(user_input, records, learning)

    suggestions: List[Tuple[float, str, Record]] = []

    for score, record in ranked:
        if len(suggestions) >= max_results:
            break

        best_name = record["name"].lower()

        # Skip if it's the same command (no correction needed)
        if best_name == typed_command:
            continue

        # Reject weak guesses
        if score < 0.45:
            continue

        # Build corrected command
        corrected = build_corrected_command(record, parts)
        suggestions.append((score, corrected, record))

    return suggestions


def explain_suggestion(
    score: float,
    record: Record,
    user_input: str,
) -> str:
    """Generate a human-readable explanation for a suggestion."""
    parts = split_input(user_input)
    if not parts:
        return ""

    typed = parts[0]
    correct = record["name"]

    reasons = []

    # Name similarity
    sim = text_similarity(typed, correct)
    if sim >= 0.80:
        reasons.append("very similar name")
    elif sim >= 0.60:
        reasons.append("similar name")
    elif phonetic_similarity(typed, correct) >= 0.70:
        reasons.append("phonetically similar")

    # Structure
    struct = structure_similarity(parts, record["syntax"])
    if struct >= 0.80:
        reasons.append("matches expected structure")

    # Category
    if record.get("category"):
        reasons.append(f"category: {record['category']}")

    # Confidence level
    if score >= 0.85:
        confidence = "high"
    elif score >= 0.65:
        confidence = "medium"
    else:
        confidence = "low"

    reason_text = ", ".join(reasons) if reasons else "best match"
    return f"[{confidence}] {reason_text}"

# ============================================================
# AUTO-DISCOVERY
# ============================================================


# Commands to skip during discovery
SKIP_COMMANDS = {
    # Termux internal
    "bash", "sh", "dash", "zsh", "fish",
    # System
    "init", "logd", "servicemanager", "vold",
    # Editors (interactive)
    "vi", "vim", "nano", "emacs", "ed",
    # Interactive shells
    "login", "su", "sudo",
    # Network daemons
    "sshd", "telnetd", "ftpd",
    # Other
    "dalvikvm", "app_process", "linker",
}

# Minimum description length to be useful
MIN_DESCRIPTION_LENGTH = 10


def discover_installed_commands() -> List[str]:
    """
    Scan PATH directories and return all executable commands.
    """
    path_var = os.environ.get("PATH", "")
    path_dirs = path_var.split(os.pathsep)

    commands = set()

    for directory in path_dirs:
        if not directory or not os.path.isdir(directory):
            continue

        try:
            entries = os.listdir(directory)
        except OSError:
            continue

        for entry in entries:
            full_path = os.path.join(directory, entry)

            # Skip directories
            if not os.path.isfile(full_path):
                continue

            # Skip non-executable
            if not os.access(full_path, os.X_OK):
                continue

            # Skip known internal commands
            if entry in SKIP_COMMANDS:
                continue

            # Skip names with weird characters
            if not re.fullmatch(r"[A-Za-z0-9_.+-]+", entry):
                continue

            commands.add(entry)

    return sorted(commands)


def read_command_help(command: str) -> Dict[str, str]:
    """
    Run 'command --help' and extract useful information.
    Returns dict with keys: name, description, usage, options
    """
    info = {
        "name": command,
        "description": "",
        "usage": "",
        "options": "",
    }

    # Try different help flags
    help_flags = [
        ["--help"],
        ["-h"],
        ["help"],
        [],
    ]

    output = ""

    for flags in help_flags:
        try:
            result = subprocess.run(
                [command] + flags,
                capture_output=True,
                text=True,
                timeout=3,
                stdin=subprocess.DEVNULL,
            )

            candidate = (result.stdout or "") + (result.stderr or "")

            if candidate.strip():
                output = candidate
                break

        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            continue

    if not output:
        return info

    lines = output.split("\n")

    # Extract description (first meaningful line)
    for line in lines[:30]:
        stripped = line.strip()
        if (
            stripped
            and len(stripped) >= MIN_DESCRIPTION_LENGTH
            and not stripped.lower().startswith("usage")
            and not stripped.startswith("-")
            and ":" not in stripped[:20]
        ):
            info["description"] = stripped[:200]
            break

    # Extract usage line
    for line in lines:
        lowered = line.lower().strip()
        if lowered.startswith("usage:") or lowered.startswith("usage "):
            info["usage"] = line.strip()[:200]
            break

    # Extract options (lines starting with -)
    option_lines = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("-") and len(stripped) > 2:
            option_lines.append(stripped.split()[0])
            if len(option_lines) >= 10:
                break

    info["options"] = " ".join(option_lines)

    return info


def get_next_command_id(database_file: str = DATABASE_FILE) -> int:
    """
    Find the next available ID in the database.
    """
    max_id = 8000  # Start auto-discovered commands from 8000
    try:
        with open(database_file, "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("C|"):
                    try:
                        current = int(line.split("|")[1])
                        if current >= 8000:
                            max_id = max(max_id, current)
                    except (ValueError, IndexError):
                        continue
    except OSError:
        pass

    return max_id + 1


def command_exists_in_db(
    command: str,
    records: List[Record],
) -> bool:
    """Check if a command is already in the database."""
    command_lower = command.lower()
    for record in records:
        if record["name"].lower() == command_lower:
            return True
    return False


def classify_command(command: str, help_text: str) -> str:
    """
    Guess the category of a command from its name and help.
    """
    text = (command + " " + help_text).lower()

    if any(w in text for w in ("install", "package", "repository")):
        return "package"
    if any(w in text for w in ("network", "http", "url", "socket", "port")):
        return "network"
    if any(w in text for w in ("file", "directory", "path")):
        return "filesystem"
    if any(w in text for w in ("text", "string", "pattern", "regex")):
        return "text"
    if any(w in text for w in ("process", "signal", "kill", "pid")):
        return "process"
    if any(w in text for w in ("git", "version control", "commit")):
        return "development"
    if any(w in text for w in ("video", "audio", "image", "media", "convert")):
        return "media"
    if any(w in text for w in ("database", "sql", "query")):
        return "database"

    return "external"


def auto_add_to_database(
    command: str,
    info: Dict[str, str],
    database_file: str = DATABASE_FILE,
) -> bool:
    """
    Append a new command to the database file.
    """
    if not info.get("description") and not info.get("usage"):
        return False

    next_id = get_next_command_id(database_file)
    command_id = f"{next_id:04d}"

    name = info.get("name", command)
    syntax = info.get("usage", name) or name
    description = info.get("description", "Auto-discovered command")
    category = classify_command(name, description)
    example = f"{name} --help"

    # Sanitize fields (remove pipes and newlines)
    def clean(text: str) -> str:
        return text.replace("|", "/").replace("\n", " ").strip()

    new_line = (
        f"C|{command_id}|{clean(name)}|external|{clean(category)}|"
        f"{clean(syntax)}|{clean(description)}|{clean(example)}|discovered\n"
    )

    try:
        with open(database_file, "a", encoding="utf-8") as f:
            f.write(new_line)
        return True
    except OSError:
        return False

# ============================================================
# PACKAGE INSTALLATION MODE
# ============================================================

# Commands that trigger package installation
INSTALL_TRIGGERS = {
    "pkg":    ["install", "add"],
    "apt":    ["install"],
    "apt-get": ["install"],
    "pip":    ["install"],
    "pip3":   ["install"],
    "npm":    ["install", "i", "add"],
    "yarn":   ["add"],
    "pnpm":   ["add"],
    "gem":    ["install"],
    "cargo":  ["install"],
    "go":     ["install", "get"],
}


def is_install_command(user_input: str) -> Tuple[bool, str, List[str]]:
    """
    Check if the input is a package installation command.
    
    Returns:
        (is_install, manager, packages)
        - is_install: True if it's an install command
        - manager: "pkg" / "apt" / "pip" / ...
        - packages: list of package names to install
    """
    parts = split_input(user_input)
    if not parts or len(parts) < 2:
        return False, "", []

    manager = parts[0].lower()
    action = parts[1].lower()

    if manager not in INSTALL_TRIGGERS:
        return False, "", []

    if action not in INSTALL_TRIGGERS[manager]:
        return False, "", []

    # Extract package names (skip flags)
    packages = []
    for part in parts[2:]:
        if part.startswith("-"):
            continue
        packages.append(part)

    if not packages:
        return False, "", []

    return True, manager, packages


def run_install_command(user_input: str) -> int:
    """
    Run a package installation command in Termux.
    Shows progress to user in English.
    """
    is_install, manager, packages = is_install_command(user_input)

    if not is_install:
        return 1

    print("=" * 50)
    print("  INSTALLING PACKAGES")
    print("=" * 50)
    print()
    print(f"  Package Manager : {manager}")
    print(f"  Packages        : {', '.join(packages)}")
    print()
    print("-" * 50)
    print()

    # Build the actual command
    command_parts = [manager]

    # Add the action (install / add)
    if manager in ("pkg", "apt", "apt-get", "pip", "pip3", "gem"):
        command_parts.append("install")
    elif manager in ("npm",):
        command_parts.append("install")
    elif manager in ("yarn", "pnpm"):
        command_parts.append("add")
    elif manager == "cargo":
        command_parts.append("install")
    elif manager == "go":
        command_parts.append("install")
    else:
        command_parts.append("install")

    # Add packages
    command_parts.extend(packages)

    print(f"Running: {' '.join(command_parts)}")
    print()

    # Run the installation
    try:
        result = subprocess.run(
            command_parts,
            check=False,
        )

        exit_code = result.returncode

    except FileNotFoundError:
        print()
        print(f"[ERROR] Package manager '{manager}' not found.")
        return 1

    except KeyboardInterrupt:
        print()
        print("[INFO] Installation cancelled by user.")
        return 1

    print()
    print("-" * 50)
    print()

    if exit_code == 0:
        print("[OK] Installation completed successfully.")
        print()

        # Auto-learn the installed packages
        print("[AI] Learning installed commands...")
        print()

        learned = 0
        skipped = 0

        for package in packages:
            # Try to learn each package as a command
            import shutil
            if not shutil.which(package):
                # Package name may differ from command name
                # Try common variations
                variations = [
                    package,
                    package.replace("-", ""),
                    package.split("-")[0],
                ]

                found = False
                for variant in variations:
                    if shutil.which(variant):
                        package = variant
                        found = True
                        break

                if not found:
                    skipped += 1
                    continue

            # Check if already in DB
            records = load_command_records()
            if command_exists_in_db(package, records):
                skipped += 1
                continue

            # Read help and add
            info = read_command_help(package)

            if not info.get("description") and not info.get("usage"):
                skipped += 1
                continue

            if auto_add_to_database(package, info):
                learned += 1
                print(f"  [OK] Learned: {package}")

        print()
        if learned > 0:
            print(f"[AI] Added {learned} new command(s) to database.")
        if skipped > 0:
            print(f"[AI] Skipped {skipped} (not found or already known).")

        return 0

    else:
        print(f"[ERROR] Installation failed (exit code: {exit_code}).")
        print()
        print("Possible causes:")
        print("  - Package name is incorrect")
        print("  - Network connection issue")
        print("  - Repository is not updated (try: pkg update)")
        return exit_code

def run_discovery_mode() -> int:
    """
    Main entry for --discover mode.
    Scans system, finds new commands, adds them to database.
    """
    print("DISCOVER MODE")
    print("=" * 32)
    print()

    print("[1/4] Loading database...")
    records = load_command_records()
    known_names = {r["name"].lower() for r in records}
    print(f"      Database has {len(records)} commands.")
    print()

    print("[2/4] Scanning installed commands...")
    installed = discover_installed_commands()
    print(f"      Found {len(installed)} executable commands.")
    print()

    # Filter new commands
    new_commands = [
        cmd for cmd in installed
        if cmd.lower() not in known_names
    ]
    print(f"[3/4] New commands: {len(new_commands)}")
    print()

    if not new_commands:
        print("Nothing to add. Database is up to date.")
        return 0

    print("[4/4] Analyzing new commands...")
    print()

    added = 0
    skipped = 0

    for i, command in enumerate(new_commands, 1):
        print(f"  [{i}/{len(new_commands)}] {command}", end=" ... ")

        info = read_command_help(command)

        if not info.get("description") and not info.get("usage"):
            print("SKIP (no help)")
            skipped += 1
            continue

        if auto_add_to_database(command, info):
            print("ADDED")
            added += 1
        else:
            print("FAILED")
            skipped += 1

    print()
    print("=" * 32)
    print(f"Summary:")
    print(f"  Added:   {added}")
    print(f"  Skipped: {skipped}")
    print(f"  Total:   {added + skipped}")
    print()

    if added > 0:
        print("Restart the app to use the new commands.")

    return 0


def run_learning_mode(command: str) -> int:
    """
    Main entry for --learn mode.
    Learns a specific command and adds it to database.
    """
    if not command:
        print("No command specified.")
        return 1

    print("LEARN MODE")
    print("=" * 32)
    print()

    print(f"Command: {command}")
    print()

    # Check if command exists
    import shutil
    if not shutil.which(command):
        print(f"[ERROR] Command '{command}' is not installed.")
        print("        Install it first with: pkg install " + command)
        return 1

    # Check if already in DB
    records = load_command_records()
    if command_exists_in_db(command, records):
        print(f"[INFO] Command '{command}' is already in the database.")
        return 0

    print("[1/2] Reading --help...")
    info = read_command_help(command)

    if not info.get("description") and not info.get("usage"):
        print("      No useful help information found.")
        print("      Cannot learn this command.")
        return 1

    print(f"      Description: {info.get('description', 'N/A')[:80]}")
    print(f"      Usage:       {info.get('usage', 'N/A')[:80]}")
    print()

    print("[2/2] Adding to database...")
    if auto_add_to_database(command, info):
        print("      Added successfully!")
        print()
        print("Restart the app to use this command.")
        return 0
    else:
        print("      Failed to add.")
        return 1

# ============================================================
# MAIN
# ============================================================

def print_suggestions(
    suggestions: List[Tuple[float, str, Record]],
    user_input: str,
) -> None:
    """Pretty-print suggestions."""
    if not suggestions:
        print("No close correction found.")
        return

    print(f"Found {len(suggestions)} suggestion(s):\n")

    for i, (score, corrected, record) in enumerate(suggestions, 1):
        explanation = explain_suggestion(score, record, user_input)
        print(f"  {i}. {corrected}")
        print(f"     score: {score:.2f}  {explanation}")
        print(f"     {record.get('description', '')}")
        print()


def main() -> int:
    print("================================")
    print("      ADVANCED AI v4.0")
    print("================================")
    print()

    print("Loading database...")
    records = load_command_records()

    if not records:
        print()
        print("AI initialization failed.")
        return 1

    print(f"Loaded {len(records)} commands.")

    # Load learning store
    learning = LearningStore()

    print("AI is ready.")
    print()

    if len(sys.argv) <= 1:
        return 0
    
    # Handle special modes
    first_arg = sys.argv[1]
    
    if first_arg == "--discover":
        return run_discovery_mode()
    
    if first_arg == "--learn":
        if len(sys.argv) < 3:
            print("Usage: advanced_ai.py --learn COMMAND")
            return 1
        return run_learning_mode(sys.argv[2])
        
    if first_arg == "--install":
        user_command = " ".join(sys.argv[2:]).strip()
        if not user_command:
            print("Usage: advanced_ai.py --install COMMAND")
            return 1
        return run_install_command(user_command)
    
    # Normal correction mode
    user_input = " ".join(sys.argv[1:]).strip()
    
    if not user_input:
        print("No command supplied.")
        return 0
    
    # Apply preprocessing
    original_input = user_input
    user_input = fix_common_typos(user_input)
    user_input = expand_abbreviations(user_input)

    if user_input != original_input:
        print(f"Preprocessed: {user_input}")
        print()

    # Check known corrections first
    known = learning.get_known_correction(original_input)
    if known:
        print("Known correction:")
        print(known)
        print()
        return 0

    # Generate suggestions
    suggestions = suggest_commands(user_input, records, learning)

    print_suggestions(suggestions, user_input)

    # Record the query (for learning)
    if suggestions:
        parts = split_input(user_input)
        if parts:
            learning.record_correction(parts[0], suggestions[0][1])

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
ADVANCED_AI_PY_EOF
        print_ok "Created $ADVANCED_AI_TARGET"
    fi

    if [ ! -f "$ADVANCED_DB_TARGET" ]; then
        cat > "$ADVANCED_DB_TARGET" << 'ADVANCED_DB_EOF'
# ADVANCED DATABASE
# VERSION=1
# FORMAT=C|ID|NAME|TYPE|CATEGORY|SYNTAX|DESCRIPTION|EXAMPLE|PACKAGE
# TYPE=builtin|external|termux|package
# ================================================================

# ---------------- SHELL BUILTINS ----------------

C|0001|cd|builtin|shell|cd [DIRECTORY]|Change the current directory|cd ~/storage/shared|bash
C|0002|pwd|builtin|shell|pwd|Show the current directory path|pwd|bash
C|0003|echo|builtin|shell|echo [TEXT]|Print text or a value|echo Hello|bash
C|0004|printf|builtin|shell|printf FORMAT [ARGUMENT]...|Print formatted text|printf "%s\n" "Hello"|bash
C|0005|read|builtin|shell|read [OPTION] [NAME]...|Read input from the user|read name|bash
C|0006|export|builtin|shell|export NAME[=VALUE]|Create or export an environment variable|export PATH="$PATH:$HOME/bin"|bash
C|0007|unset|builtin|shell|unset NAME...|Remove a variable|unset name|bash
C|0008|set|builtin|shell|set [OPTION] [ARGUMENT]...|Change shell settings or variables|set -u|bash
C|0009|source|builtin|shell|source FILE|Execute a file in the current shell|source script.sh|bash
C|0010|alias|builtin|shell|alias [NAME[=VALUE]]|Create a command alias|alias ll='ls -la'|bash
C|0011|unalias|builtin|shell|unalias NAME|Remove an alias|unalias ll|bash
C|0012|type|builtin|shell|type NAME...|Show the type and location of a command|type ls|bash
C|0013|command|builtin|shell|command [OPTION] [NAME [ARG]...]|Run or inspect a command without aliases|command -v ls|bash
C|0014|test|builtin|shell|test EXPRESSION|Evaluate a condition|test -f file.txt|bash
C|0015|true|builtin|shell|true|Return a successful status|true|bash
C|0016|false|builtin|shell|false|Return a failure status|false|bash
C|0017|return|builtin|shell|return [N]|Return from a function or sourced script|return 0|bash
C|0018|exit|builtin|shell|exit [N]|Exit the shell|exit 0|bash
C|0019|exec|builtin|shell|exec COMMAND [ARGUMENT]...|Replace the current shell with another command|exec bash|bash
C|0020|wait|builtin|shell|wait [PID]|Wait for a process|wait|bash
C|0021|shift|builtin|shell|shift [N]|Shift positional parameters|shift 1|bash
C|0022|trap|builtin|shell|trap ACTION SIGNAL...|Run an action when a signal is received|trap 'echo stop' INT|bash
C|0023|help|builtin|shell|help [PATTERN]|Show help for Bash builtins|help cd|bash
C|0024|history|builtin|shell|history [N]|Show command history|history 20|bash
C|0025|local|builtin|shell|local NAME[=VALUE]|Create a local variable inside a function|local name="Mustafa"|bash
C|0026|eval|builtin|shell|eval ARG...|Evaluate arguments as a shell command|eval "$cmd"|bash
C|0027|jobs|builtin|shell|jobs [-l] [-p]|Show background jobs|jobs|bash
C|0028|fg|builtin|shell|fg [JOB_SPEC]|Bring a job to the foreground|fg %1|bash
C|0029|bg|builtin|shell|bg [JOB_SPEC]|Resume a stopped job in the background|bg %1|bash

# ---------------- FILESYSTEM ----------------

C|0101|ls|external|filesystem|ls [OPTION]... [FILE]...|List files and directories|ls -la|coreutils
C|0102|cp|external|filesystem|cp [OPTION] SOURCE DEST|Copy files or directories|cp file.txt backup.txt|coreutils
C|0103|mv|external|filesystem|mv [OPTION] SOURCE DEST|Move or rename files or directories|mv old.txt new.txt|coreutils
C|0104|rm|external|filesystem|rm [OPTION]... FILE...|Remove files or directories|rm file.txt|coreutils
C|0105|mkdir|external|filesystem|mkdir [OPTION]... DIRECTORY...|Create a directory|mkdir project|coreutils
C|0106|rmdir|external|filesystem|rmdir [OPTION]... DIRECTORY...|Remove an empty directory|rmdir olddir|coreutils
C|0107|touch|external|filesystem|touch [OPTION]... FILE...|Create a file or update its timestamp|touch main.sh|coreutils
C|0108|cat|external|filesystem|cat [OPTION]... [FILE]...|Display file contents|cat main.sh|coreutils
C|0109|head|external|text|head [OPTION]... [FILE]...|Display the beginning of a file|head -n 20 file.txt|coreutils
C|0110|tail|external|text|tail [OPTION]... [FILE]...|Display the end of a file|tail -n 20 file.txt|coreutils
C|0111|wc|external|text|wc [OPTION]... [FILE]...|Count lines, words, and characters|wc -l file.txt|coreutils
C|0112|sort|external|text|sort [OPTION]... [FILE]...|Sort lines|sort names.txt|coreutils
C|0113|uniq|external|text|uniq [OPTION]... [INPUT [OUTPUT]]|Remove adjacent duplicate lines|sort names.txt | uniq|coreutils
C|0114|cut|external|text|cut OPTION... [FILE]...|Extract parts of each line|cut -d: -f1 file.txt|coreutils
C|0115|tr|external|text|tr [OPTION] SET1 [SET2]|Translate or delete characters|tr a-z A-Z|coreutils
C|0116|paste|external|text|paste [OPTION] [FILE]...|Merge lines from files|paste file1.txt file2.txt|coreutils
C|0117|tee|external|text|tee [OPTION]... [FILE]...|Write input to output and files|echo hello | tee output.txt|coreutils
C|0118|xargs|external|text|xargs [OPTION]... [COMMAND [INITIAL-ARGS]]|Build command arguments from input|printf "%s\n" a b | xargs echo|findutils
C|0119|basename|external|filesystem|basename NAME [SUFFIX]|Extract the filename from a path|basename /tmp/test.txt|coreutils
C|0120|dirname|external|filesystem|dirname NAME|Extract the directory from a path|dirname /tmp/test.txt|coreutils
C|0121|realpath|external|filesystem|realpath [OPTION]... FILE...|Show the canonical path|realpath file.txt|coreutils
C|0122|readlink|external|filesystem|readlink [OPTION]... FILE|Read a symbolic link|readlink link.txt|coreutils
C|0123|stat|external|filesystem|stat [OPTION]... FILE...|Show file information|stat file.txt|coreutils
C|0124|du|external|filesystem|du [OPTION]... [FILE]...|Show disk usage|du -sh .|coreutils
C|0125|df|external|filesystem|df [OPTION]... [FILE]...|Show available disk space|df -h|coreutils
C|0126|chmod|external|permissions|chmod [OPTION]... MODE FILE...|Change file permissions|chmod +x script.sh|coreutils
C|0127|chown|external|permissions|chown [OPTION]... OWNER[:GROUP] FILE...|Change file ownership|chown user file.txt|coreutils
C|0128|ln|external|filesystem|ln [OPTION]... TARGET LINK_NAME|Create a link|ln -s target link|coreutils
C|0129|file|external|filesystem|file [OPTION]... FILE...|Determine the file type|file image.png|file

# ---------------- TEXT PROCESSING ----------------

C|0130|grep|external|text|grep [OPTION]... PATTERN [FILE]...|Search for text in files|grep -n "hello" file.txt|grep
C|0131|sed|external|text|sed [OPTION]... SCRIPT [INPUT-FILE]...|Process and edit text|sed 's/old/new/g' file.txt|sed
C|0132|awk|external|text|awk [OPTION]... PROGRAM [FILE]...|Process structured text data|awk '{print $1}' file.txt|gawk
C|0133|find|external|filesystem|find PATH... EXPRESSION|Search for files and directories|find . -name "*.sh"|findutils
C|0134|diff|external|text|diff [OPTION]... FILE1 FILE2|Compare files|diff old.txt new.txt|diffutils
C|0135|cmp|external|text|cmp [OPTION]... FILE1 [FILE2 [SKIP1 [SKIP2]]]|Compare files byte by byte|cmp a.bin b.bin|diffutils
C|0136|comm|external|text|comm [OPTION]... FILE1 FILE2|Compare sorted files|comm file1 file2|coreutils
C|0137|strings|external|text|strings [OPTION] [FILE]...|Extract readable strings from files|strings app.bin|binutils

# ---------------- SYSTEM / PROCESS ----------------

C|0201|id|external|system|id [OPTION]... [USER]|Show user and group IDs|id|coreutils
C|0202|whoami|external|system|whoami|Show the current username|whoami|coreutils
C|0203|uname|external|system|uname [OPTION]...|Show system information|uname -a|coreutils
C|0204|hostname|external|system|hostname [OPTION] [NAME]|Show or set the hostname|hostname|coreutils
C|0205|date|external|system|date [OPTION]... [+FORMAT]|Show date and time|date '+%Y-%m-%d'|coreutils
C|0206|sleep|external|system|sleep NUMBER[SUFFIX]...|Wait for a specified time|sleep 2|coreutils
C|0207|env|external|environment|env [OPTION]... [-] [NAME=VALUE]... [COMMAND [ARG]...]|Show or modify the execution environment|env|coreutils
C|0208|printenv|external|environment|printenv [OPTION]... [VARIABLE]...|Show environment variables|printenv HOME|coreutils
C|0209|ps|external|process|ps [OPTION]...|Show running processes|ps|procps
C|0210|pgrep|external|process|pgrep [OPTION]... PATTERN|Find processes by name|pgrep bash|procps
C|0211|pkill|external|process|pkill [OPTION]... PATTERN|Send a signal to matching processes|pkill process_name|procps
C|0212|kill|builtin|process|kill [-SIGNAL] PID...|Send a signal to a process|kill 1234|bash
C|0213|killall|external|process|killall [OPTION]... NAME...|Send a signal to processes by name|killall appname|psmisc
C|0214|top|external|process|top [OPTION]...|Monitor processes and resource usage|top|procps
C|0215|free|external|system|free [OPTION]...|Show memory usage|free -h|procps
C|0216|uptime|external|system|uptime [OPTION]...|Show system uptime|uptime|procps
C|0217|nice|external|process|nice [OPTION] [COMMAND [ARG]...]|Run a command with a different priority|nice -n 5 command|coreutils
C|0218|renice|external|process|renice [OPTION] -n INCREMENT [PID... | PGID... | USER... ]|Change process priority|renice -n 5 -p 1234|util-linux

# ---------------- ARCHIVES / COMPRESSION ----------------

C|0301|tar|external|archive|tar [OPTION]... [FILE]...|Create and extract tar archives|tar -cf archive.tar folder|tar
C|0302|gzip|external|archive|gzip [OPTION]... [FILE]...|Compress files with gzip|gzip file.txt|gzip
C|0303|gunzip|external|archive|gunzip [OPTION]... [FILE]...|Decompress gzip files|gunzip file.txt.gz|gzip
C|0304|bzip2|external|archive|bzip2 [OPTION]... [FILE]...|Compress using bzip2|bzip2 file.txt|bzip2
C|0305|bunzip2|external|archive|bunzip2 [OPTION]... [FILE]...|Decompress bzip2 files|bunzip2 file.txt.bz2|bzip2
C|0306|xz|external|archive|xz [OPTION]... [FILE]...|Compress using xz|xz file.txt|xz-utils
C|0307|unxz|external|archive|unxz [OPTION]... [FILE]...|Decompress xz files|unxz file.txt.xz|xz-utils
C|0308|zip|external|archive|zip [OPTION]... ZIPFILE FILE...|Create a zip archive|zip files.zip file.txt|zip
C|0309|unzip|external|archive|unzip [OPTION] ZIPFILE [FILE...]|Extract a zip archive|unzip files.zip|unzip
C|0310|zcat|external|archive|zcat [OPTION]... [FILE]...|Display gzip content without manual extraction|zcat file.txt.gz|gzip

# ---------------- NETWORK ----------------

C|0401|curl|external|network|curl [OPTION]... [URL]|Transfer data over the network|curl https://example.com|curl
C|0402|ping|external|network|ping [OPTION]... HOST|Test network reachability|ping example.com|inetutils
C|0403|ping6|external|network|ping6 [OPTION]... HOST|Test IPv6 connectivity|ping6 example.com|inetutils
C|0404|nc|external|network|nc [OPTION]... HOST PORT|General network connection utility|nc host 80|netcat-openbsd
C|0405|netstat|external|network|netstat [OPTION]...|Show network connections|netstat -an|net-tools
C|0406|ifconfig|external|network|ifconfig [INTERFACE] [OPTIONS]|Show or configure network interfaces|ifconfig|net-tools

# ---------------- PACKAGE MANAGEMENT ----------------

C|0501|pkg|termux|package|pkg COMMAND [PACKAGE...]|Simplified Termux package manager interface|pkg install python|termux-tools
C|0502|apt|external|package|apt [OPTION] COMMAND|Manage packages and repositories|apt update|apt
C|0503|apt-get|external|package|apt-get [OPTION] COMMAND|Low-level APT package management|apt-get update|apt
C|0504|apt-cache|external|package|apt-cache COMMAND [PACKAGE...]|Search and inspect package information|apt-cache search python|apt
C|0505|apt-mark|external|package|apt-mark COMMAND [PACKAGE...]|Manage manually and automatically installed package states|apt-mark showmanual|apt
C|0506|dpkg|external|package|dpkg [OPTION...] ACTION|Manage Debian packages|dpkg -l|dpkg
C|0507|dpkg-deb|external|package|dpkg-deb [OPTION...] COMMAND|Inspect and create deb packages|dpkg-deb -I package.deb|dpkg

# ---------------- TERMUX TOOLS ----------------

C|0601|termux-setup-storage|termux|termux|termux-setup-storage|Set up storage access and storage links|termux-setup-storage|termux-tools
C|0602|termux-open|termux|termux|termux-open [OPTIONS] PATH_OR_URL|Open a file or URL with an external application|termux-open file.txt|termux-tools
C|0603|termux-open-url|termux|termux|termux-open-url URL [APP_PACKAGE_OR_COMPONENT]|Open a URL|termux-open-url https://example.com|termux-tools
C|0604|termux-info|termux|termux|termux-info|Show Termux environment information|termux-info|termux-tools
C|0605|termux-change-repo|termux|termux|termux-change-repo|Change Termux repositories|termux-change-repo|termux-tools
C|0606|termux-fix-shebang|termux|termux|termux-fix-shebang FILE...|Fix shebang lines for Termux|termux-fix-shebang script.sh|termux-tools
C|0607|termux-reload-settings|termux|termux|termux-reload-settings|Reload Termux settings|termux-reload-settings|termux-tools
C|0608|termux-reset|termux|termux|termux-reset|Reset the Termux terminal state|termux-reset|termux-tools
C|0609|termux-backup|termux|termux|termux-backup OUTPUT_FILE|Create a backup of the Termux environment|termux-backup backup.tar.gz|termux-tools
C|0610|termux-restore|termux|termux|termux-restore INPUT_FILE|Restore a Termux backup|termux-restore backup.tar.gz|termux-tools
C|0611|termux-setup-package-manager|termux|termux|termux-setup-package-manager|Set up the package manager|termux-setup-package-manager|termux-tools
C|0612|termux-wake-lock|termux|termux|termux-wake-lock|Prevent the device from sleeping|termux-wake-lock|termux-tools
C|0613|termux-wake-unlock|termux|termux|termux-wake-unlock|Allow the device to sleep again|termux-wake-unlock|termux-tools
C|0614|chsh|termux|termux|chsh [OPTION] [LOGIN_SHELL]|Change the default shell|chsh|termux-tools
C|0615|login|termux|termux|login [OPTION] [USERNAME]|Start a login session|login|termux-tools
C|0616|dalvikvm|termux|android|dalvikvm [OPTIONS] CLASSNAME|Run the Dalvik virtual machine|dalvikvm|termux-tools
C|0617|getprop|termux|android|getprop [PROPERTY]|Read Android system properties|getprop|termux-tools
C|0618|logcat|termux|android|logcat [OPTIONS]|Display Android system logs|logcat|termux-tools
C|0619|pm|termux|android|pm [COMMAND] [PACKAGE]|Manage Android packages|pm list packages|termux-tools
C|0620|settings|termux|android|settings [COMMAND] [NAMESPACE] [KEY] [VALUE]|Read or modify Android settings|settings list system|termux-tools
C|0621|mount|termux|android|mount [OPTIONS]|Show or perform mount operations when permitted|mount|termux-tools
C|0622|umount|termux|android|umount [OPTIONS] TARGET|Unmount a filesystem|umount TARGET|termux-tools
C|0623|xdg-open|termux|termux|xdg-open PATH_OR_URL|Open a file or URL|xdg-open file.txt|termux-tools

# ---------------- OPTIONAL COMMON TOOLS ----------------

C|0701|wget|external|network|wget [OPTION]... [URL]...|Download files over HTTP or HTTPS|wget https://example.com/file.zip|wget
C|0702|git|external|development|git [--version] [COMMAND] [OPTIONS]|Distributed version control system|git status|git
C|0703|ssh|external|network|ssh [OPTION]... [HOST] [COMMAND]|Connect to a remote SSH server|ssh user@host|openssh
C|0704|scp|external|network|scp [OPTION] SOURCE... TARGET|Copy files over SSH|scp file user@host:path|openssh
C|0705|sftp|external|network|sftp [OPTION]... [USER@]HOST|Transfer files using SFTP|sftp user@host|openssh
C|0706|vim|external|editor|vim [OPTION]... [FILE]...|Advanced text editor|vim main.sh|vim
C|0707|nano|external|editor|nano [OPTION]... [FILE]...|Simple text editor|nano main.sh|nano
C|0708|less|external|text|less [OPTION]... [FILE]...|Read files page by page|less main.sh|less
C|0709|more|external|text|more [OPTION]... FILE...|Display text page by page|more file.txt|util-linux
C|0710|tree|external|filesystem|tree [OPTION] [DIRECTORY]|Display directories as a tree|tree|tree
C|0711|jq|external|text|jq [OPTIONS] FILTER [FILE...]|Process JSON data|jq '.name' data.json|jq
C|0712|dialog|external|interface|dialog [OPTION]...|Create text-based interfaces|dialog --msgbox "Hello" 10 30|dialog
C|0713|watch|external|process|watch [OPTION] COMMAND|Run a command repeatedly to monitor its output|watch ls|procps
C|0714|timeout|external|process|timeout [OPTION] DURATION COMMAND [ARG]...|Run a command with a time limit|timeout 5s command|coreutils

# ---------------- COMMON ERROR KNOWLEDGE ----------------

E|9001|command not found|The command does not exist or was typed incorrectly|Check the command name and search for the closest registered command|command
E|9002|No such file or directory|The specified file or directory does not exist|Check the path, filename, and whether the target exists|filesystem
E|9003|Permission denied|The operation does not have sufficient permission|Check file permissions or the required operation permissions|permissions
E|9004|Is a directory|A directory was used where a file was expected|Select the correct file or use the appropriate directory command|filesystem
E|9005|Not a directory|Part of the specified path is not a directory|Check each part of the path|filesystem
E|9006|File exists|The requested target already exists|Choose another name or use the appropriate option|filesystem
E|9007|missing operand|A required argument is missing|Check the command SYNTAX and provide the missing argument|syntax
E|9008|invalid option|An invalid command option was provided|Check the available options or use --help|syntax
E|9009|too many arguments|Too many arguments were provided|Compare the command with the registered SYNTAX|syntax
E|9010|cannot open|The file or resource could not be opened|Check the name, path, and permissions|filesystem
E|9011|cannot create|The file or directory could not be created|Check the path, available storage, and permissions|filesystem
E|9012|not found|The requested item could not be found|Check the name and path|filesystem
E|9013|E: Unable to locate package|The package could not be found in the current package indexes|Check the package name and update package indexes|package
E|9014|dpkg was interrupted|A dpkg operation did not finish correctly|Check the package manager state before continuing|package
E|9015|Could not get lock|Another process is using the package manager|Make sure another package process is not running|package
E|9016|Syntax error|The shell command or script has invalid syntax|Check the syntax, brackets, and quotes|syntax
E|9017|unterminated quoted string|A quoted string was not closed|Check all quotation marks in the command|syntax
E|9018|command failed|The command exited with a failure status|Read the error message and inspect the command and arguments|general

# ---------------- CORRECTION RULES ----------------

R|001|COMMAND_NOT_FOUND|First search for an exact NAME match, then find the closest command name|NAME
R|002|BAD_SYNTAX|Compare the provided arguments with the command SYNTAX|SYNTAX
R|003|MISSING_ARGUMENT|Check the required fields in SYNTAX|SYNTAX
R|004|INVALID_OPTION|Compare the options with the available OPTIONS or updated tool data|OPTIONS
R|005|PATH_ERROR|Check the path and its parent directory before suggesting a correction|PATH
R|006|PACKAGE_ERROR|Search package data for the package name|PACKAGE
ADVANCED_DB_EOF
        print_ok "Created $ADVANCED_DB_TARGET"
    fi

    # ============================================================
    # EXTERNAL AI - CONFIGURATION FILES
    # ============================================================
    SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
    API_DIR="$SCRIPT_DIR"
    API_CONFIG="$API_DIR/api_config.json"
    API_CLIENT="$API_DIR/api_client.py"

    mkdir -p "$API_DIR" 2>/dev/null
    chmod 700 "$API_DIR" 2>/dev/null

    if [ ! -f "$API_CONFIG" ]; then
        cat > "$API_CONFIG" << 'API_CONFIG_JSON_EOF'
{
  "provider": "openai",
  "url": "https://api.openai.com/v1",
  "model": "gpt-4o-mini",
  "key": "",
  "max_tokens": 8192,
  "timeout": 300,
  "temperature": 0.3,
  "enabled": false
}
API_CONFIG_JSON_EOF
        chmod 600 "$API_CONFIG" 2>/dev/null
        print_ok "Created api_config.json"
    fi

    if [ ! -f "$API_CLIENT" ]; then
        cat > "$API_CLIENT" << 'API_CLIENT_PY_EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
External AI Client v1.0
- OpenAI-compatible API client
- Reads JSON config from stdin
- Outputs structured response
"""

import json
import sys
import urllib.request
import urllib.error


def main():
    try:
        raw = sys.stdin.read()
        data = json.loads(raw)
    except (json.JSONDecodeError, ValueError) as e:
        print("CONFIG_ERROR")
        print("Invalid JSON input: " + str(e))
        return 1

    url = data.get("url", "").strip()
    api_key = data.get("key", "").strip()
    model = data.get("model", "").strip()
    messages = data.get("messages", [])
    max_tokens = int(data.get("max_tokens", 8192))
    timeout = int(data.get("timeout", 300))
    temperature = float(data.get("temperature", 0.3))

    if not url:
        print("CONFIG_ERROR")
        print("Missing API URL")
        return 1

    if not api_key:
        print("CONFIG_ERROR")
        print("Missing API Key")
        return 1

    if not model:
        print("CONFIG_ERROR")
        print("Missing model name")
        return 1

    if not messages:
        print("CONFIG_ERROR")
        print("No messages provided")
        return 1

    endpoint = url.rstrip("/") + "/chat/completions"

    payload = {
        "model": model,
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": temperature,
    }

    try:
        body = json.dumps(payload).encode("utf-8")
    except (TypeError, ValueError) as e:
        print("CONFIG_ERROR")
        print("Payload error: " + str(e))
        return 1

    request = urllib.request.Request(
        endpoint,
        data=body,
        method="POST",
    )

    request.add_header("Content-Type", "application/json")
    request.add_header("Authorization", "Bearer " + api_key)
    request.add_header("User-Agent", "Termux-AI/4.0")

    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            response_text = response.read().decode("utf-8", errors="replace")
            result = json.loads(response_text)

            choices = result.get("choices", [])

            if not choices:
                print("API_ERROR")
                print("No choices in response")
                return 1

            message = choices[0].get("message", {})
            content = message.get("content", "")

            if not content:
                print("API_ERROR")
                print("Empty response content")
                return 1

            print("OK")
            print(content)
            return 0

    except urllib.error.HTTPError as e:
        error_body = ""

        try:
            error_body = e.read().decode("utf-8", errors="replace")
        except Exception:
            pass

        print("HTTP_" + str(e.code))

        if error_body:
            try:
                parsed = json.loads(error_body)
                err_msg = ""

                if isinstance(parsed, list) and parsed:
                    parsed = parsed[0]

                if isinstance(parsed, dict):
                    err = parsed.get("error", {})

                    if isinstance(err, dict):
                        err_msg = err.get("message", "")
                    elif err:
                        err_msg = str(err)
                else:
                    err_msg = str(parsed)

                if err_msg:
                    print(err_msg[:500])
                else:
                    print(error_body[:500])

            except (json.JSONDecodeError, ValueError):
                print(error_body[:500])

        return 1

    except urllib.error.URLError as e:
        reason = str(e.reason) if e.reason else "Unknown"

        print("NETWORK_ERROR")
        print(reason[:300])
        return 1

    except TimeoutError:
        print("TIMEOUT")
        print("Request timed out")
        return 1

    except Exception as e:
        print("UNKNOWN_ERROR")
        print(str(e)[:300])
        return 1


if __name__ == "__main__":
    sys.exit(main())
API_CLIENT_PY_EOF
        chmod 700 "$API_CLIENT" 2>/dev/null
        print_ok "Created api_client.py"
    fi

    # ============================================================
    # P2P CHAT - ENCRYPTED MESSENGER
    # ============================================================
    P2P_CHAT_TARGET="p2p_chat.py"

    if [ ! -f "$P2P_CHAT_TARGET" ]; then
        cat > "$P2P_CHAT_TARGET" << 'P2P_CHAT_PY_EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Termux AI - P2P Chat v4.1
- Auto-reconnect on startup (no internet)
- Auto-reconnect when internet returns
- Friend request approval
- Multiple chats with unread counter
- Presence (● online / ◐ away / ○ offline)
- Offline queue with auto-send
"""

import os
import sys
import json
import time
import random
import string
import subprocess
import threading
from datetime import datetime
import hashlib
import hmac
import base64

try:
    import paho.mqtt.client as mqtt
except ImportError:
    print("[ERROR] paho-mqtt not installed.")
    print("Run: pip install paho-mqtt")
    sys.exit(1)


VERSION = "4.1"
BROKER = "broker.hivemq.com"
PORT = 1883
KEEPALIVE = 30
TOPIC_MSG = "termux_ai/v4/msg/"
TOPIC_REQ = "termux_ai/v4/req/"
TOPIC_PRES = "termux_ai/v4/pres/"
TOPIC_GROUP = "termux_ai/v4/group/"
TOPIC_CMD = "termux_ai/v4/cmd/"
TOPIC_CMDRES = "termux_ai/v4/cmdres/"

PRESENCE_INTERVAL = 10
PRESENCE_TIMEOUT = 40
AWAY_TIMEOUT = 20
NETWORK_CHECK_INTERVAL = 3

SESSION_ID = os.environ.get("P2P_SESSION", "").strip()
_suffix = "_" + SESSION_ID if SESSION_ID else ""

CONFIG_FILE = os.path.expanduser("~/.termux_ai_p2p" + _suffix + ".json")
CHAT_LOG_DIR = os.path.expanduser("~/p2p_chats" + _suffix)
FILE_DIR = os.path.expanduser("~/storage/shared/Download/p2p_files" + _suffix)
FILE_DIR_FALLBACK = os.path.expanduser("~/p2p_files" + _suffix)
MAX_FILE_SIZE = 256 * 1024
MAX_CHUNKED_FILE_SIZE = 20 * 1024 * 1024
CHUNK_SIZE = 32 * 1024
TRANSFER_TIMEOUT = 180

EMOJI_MAP = {
    ":smile:": "😊", ":laugh:": "😂", ":heart:": "❤️",
    ":ok:": "👌", ":fire:": "🔥", ":up:": "👍",
    ":down:": "👎", ":cry:": "😢", ":angry:": "😠",
    ":wink:": "😉", ":cool:": "😎", ":think:": "🤔",
    ":wave:": "👋", ":clap:": "👏", ":pray:": "🙏",
    ":star:": "⭐", ":check:": "✅", ":x:": "❌",
    ":warn:": "⚠️", ":rocket:": "🚀", ":idea:": "💡",
    ":party:": "🎉", ":cat:": "🐱", ":dog:": "🐶",
    ":sun:": "☀️", ":moon:": "🌙", ":coffee:": "☕",
    ":pizza:": "🍕", ":phone:": "📱", ":pc:": "💻",
    ":book:": "📚", ":gift:": "🎁", ":love:": "🥰",
}


# ============================================================
# UTILITIES
# ============================================================

def clear():
    os.system("clear")


def gen_suffix(n=8):
    chars = string.ascii_uppercase + string.digits
    return "".join(random.choice(chars) for _ in range(n))


def gen_id(username):
    prefix = "".join(c for c in username.upper() if c.isalnum())[:6]
    if not prefix:
        prefix = "USER"
    return prefix + "_" + gen_suffix(8)


def now_short():
    return datetime.now().strftime("%H:%M")


def now_full():
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def now_filename():
    return datetime.now().strftime("%Y-%m-%d_%H-%M-%S")


def now_ts():
    return int(time.time())


def apply_emoji(text):
    for k, v in EMOJI_MAP.items():
        text = text.replace(k, v)
    return text



# ============================================================
# TRANSPARENT ENCRYPTION (hidden)
# ============================================================

_P1 = "kx9alpha"
_P2 = "v7beta"
_P3 = "qm3gamma"
_P4 = "z2delta"
_P5 = "r5omega"
_BASE_SALT = ("|".join([_P1, _P2, _P3, _P4, _P5])).encode("utf-8")


def _kdf_pair(id_a, id_b):
    ids = sorted([id_a.upper(), id_b.upper()])
    material = (ids[0] + "|" + ids[1]).encode("utf-8")
    return hashlib.pbkdf2_hmac("sha256", material, _BASE_SALT, 10000, dklen=32)


def _kdf_group(gid):
    material = ("GROUP|" + gid.upper()).encode("utf-8")
    return hashlib.pbkdf2_hmac("sha256", material, _BASE_SALT, 10000, dklen=32)


def _encrypt_text(key, text):
    try:
        data = text.encode("utf-8")
    except Exception:
        return text
    iv = os.urandom(12)
    ks = b""
    ctr = 0
    while len(ks) < len(data):
        ks += hashlib.sha256(key + iv + ctr.to_bytes(4, "big")).digest()
        ctr += 1
    ct = bytes(x ^ y for x, y in zip(data, ks))
    mac = hmac.new(key, iv + ct, hashlib.sha256).digest()[:16]
    return base64.b64encode(iv + mac + ct).decode("ascii")


def _decrypt_text(key, blob):
    try:
        raw = base64.b64decode(blob, validate=False)
        if len(raw) < 28:
            return None
        iv = raw[:12]
        mac = raw[12:28]
        ct = raw[28:]
        exp = hmac.new(key, iv + ct, hashlib.sha256).digest()[:16]
        if not hmac.compare_digest(mac, exp):
            return None
        ks = b""
        ctr = 0
        while len(ks) < len(ct):
            ks += hashlib.sha256(key + iv + ctr.to_bytes(4, "big")).digest()
            ctr += 1
        pt = bytes(x ^ y for x, y in zip(ct, ks))
        return pt.decode("utf-8", "replace")
    except Exception:
        return None


def load_config():
    if not os.path.exists(CONFIG_FILE):
        return {}
    try:
        with open(CONFIG_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def save_config(cfg):
    try:
        with open(CONFIG_FILE, "w", encoding="utf-8") as f:
            json.dump(cfg, f, ensure_ascii=False, indent=2)
        try:
            os.chmod(CONFIG_FILE, 0o600)
        except Exception:
            pass
        return True
    except Exception:
        return False


def ensure_log_dir():
    try:
        os.makedirs(CHAT_LOG_DIR, exist_ok=True)
        return True
    except Exception:
        return False


def ensure_file_dir():
    try:
        os.makedirs(FILE_DIR, exist_ok=True)
        return FILE_DIR
    except Exception:
        pass
    try:
        os.makedirs(FILE_DIR_FALLBACK, exist_ok=True)
        return FILE_DIR_FALLBACK
    except Exception:
        return None

def send_file(self, friend_name, file_path, save_path=None):
    fid = self.friends.get(friend_name)
    if not fid:
        return False, "unknown friend"
    if not self.connected:
        return False, "offline"
    try:
        file_path = os.path.expanduser(file_path)
        if not os.path.isfile(file_path):
            return False, "file not found"
        size = os.path.getsize(file_path)
        if size > MAX_CHUNKED_FILE_SIZE:
            return False, "file too large (max 20 MB)"
        if size <= MAX_FILE_SIZE:
            return _send_file_single(self, fid, file_path, save_path, friend_name)
        return _send_file_chunked(self, fid, file_path, save_path, friend_name)
    except Exception as e:
        return False, str(e)


def send_file_group(self, group_name, file_path, save_path=None):
    gname = group_name.strip().lower()
    if gname not in self.groups:
        return False, "unknown group"
    if not self.connected:
        return False, "offline"
    ginfo = self.groups[gname]
    try:
        file_path = os.path.expanduser(file_path)
        if not os.path.isfile(file_path):
            return False, "file not found"
        size = os.path.getsize(file_path)
        if size > MAX_CHUNKED_FILE_SIZE:
            return False, "file too large (max 20 MB)"
        if size <= MAX_FILE_SIZE:
            return _send_file_single_group(self, ginfo, file_path, save_path)
        return _send_file_chunked_group(self, ginfo, file_path, save_path)
    except Exception as e:
        return False, str(e)


def _send_file_single(self, fid, file_path, save_path, friend_name):
    """إرسال ملف صغير في رسالة واحدة (الطريقة القديمة)."""
    with open(file_path, "rb") as f:
        data = f.read()
    b64 = base64.b64encode(data).decode("ascii")
    enc_data = self._enc(fid, b64)
    payload = {
        "from_id": self.my_id,
        "from_name": self.username,
        "type": "file",
        "filename": os.path.basename(file_path),
        "size": len(data),
        "data": enc_data,
        "save_path": save_path if save_path else "",
        "enc": 1,
        "ts": now_short(),
    }
    self.client.publish(TOPIC_MSG + fid, json.dumps(payload, ensure_ascii=False), qos=1)
    return True, ""


def _send_file_single_group(self, ginfo, file_path, save_path):
    """إرسال ملف صغير لمجموعة (الطريقة القديمة)."""
    with open(file_path, "rb") as f:
        data = f.read()
    b64 = base64.b64encode(data).decode("ascii")
    enc_data = self._enc_g(ginfo["id"], b64)
    payload = {
        "from_id": self.my_id,
        "from_name": self.username,
        "type": "file",
        "filename": os.path.basename(file_path),
        "size": len(data),
        "data": enc_data,
        "save_path": save_path if save_path else "",
        "enc": 1,
        "ts": now_short(),
    }
    self.client.publish(ginfo["topic"], json.dumps(payload, ensure_ascii=False), qos=1)
    return True, ""


def _send_file_chunked(self, fid, file_path, save_path, friend_name):
    """إرسال ملف كبير على شكل أجزاء (لصديق)."""
    try:
        with open(file_path, "rb") as f:
            data = f.read()

        size = len(data)
        filename = os.path.basename(file_path)
        file_id = "FID_" + gen_suffix(10)
        total_chunks = (size + CHUNK_SIZE - 1) // CHUNK_SIZE

        sys.stdout.write("\n📤 Sending " + filename + " (" + str(size) + " bytes, " +
                         str(total_chunks) + " chunks)\n")
        sys.stdout.flush()

        # 1. إرسال metadata
        meta = {
            "from_id": self.my_id,
            "from_name": self.username,
            "type": "file_meta",
            "file_id": file_id,
            "filename": filename,
            "size": size,
            "total_chunks": total_chunks,
            "chunk_size": CHUNK_SIZE,
            "save_path": save_path if save_path else "",
            "enc": 1,
            "ts": now_short(),
        }
        self.client.publish(TOPIC_MSG + fid, json.dumps(meta, ensure_ascii=False), qos=1)
        time.sleep(0.15)

        # 2. إرسال كل جزء
        for i in range(total_chunks):
            chunk = data[i * CHUNK_SIZE:(i + 1) * CHUNK_SIZE]
            b64 = base64.b64encode(chunk).decode("ascii")
            enc_data = self._enc(fid, b64)
            payload = {
                "from_id": self.my_id,
                "from_name": self.username,
                "type": "file_chunk",
                "file_id": file_id,
                "index": i,
                "total": total_chunks,
                "data": enc_data,
                "enc": 1,
            }
            self.client.publish(TOPIC_MSG + fid, json.dumps(payload, ensure_ascii=False), qos=1)

            sys.stdout.write("\r  📤 Sent: " + str(i + 1) + "/" + str(total_chunks))
            sys.stdout.flush()

            time.sleep(0.05)

        sys.stdout.write("\n✅ File sent.\n> ")
        sys.stdout.flush()
        return True, ""
    except Exception as e:
        return False, str(e)


def _send_file_chunked_group(self, ginfo, file_path, save_path):
    """إرسال ملف كبير على شكل أجزاء (لمجموعة)."""
    try:
        with open(file_path, "rb") as f:
            data = f.read()

        size = len(data)
        filename = os.path.basename(file_path)
        file_id = "FID_" + gen_suffix(10)
        total_chunks = (size + CHUNK_SIZE - 1) // CHUNK_SIZE

        sys.stdout.write("\n📤 Sending " + filename + " (" + str(size) + " bytes, " +
                         str(total_chunks) + " chunks)\n")
        sys.stdout.flush()

        meta = {
            "from_id": self.my_id,
            "from_name": self.username,
            "type": "file_meta",
            "file_id": file_id,
            "filename": filename,
            "size": size,
            "total_chunks": total_chunks,
            "chunk_size": CHUNK_SIZE,
            "save_path": save_path if save_path else "",
            "enc": 1,
            "ts": now_short(),
        }
        self.client.publish(ginfo["topic"], json.dumps(meta, ensure_ascii=False), qos=1)
        time.sleep(0.15)

        for i in range(total_chunks):
            chunk = data[i * CHUNK_SIZE:(i + 1) * CHUNK_SIZE]
            b64 = base64.b64encode(chunk).decode("ascii")
            enc_data = self._enc_g(ginfo["id"], b64)
            payload = {
                "from_id": self.my_id,
                "from_name": self.username,
                "type": "file_chunk",
                "file_id": file_id,
                "index": i,
                "total": total_chunks,
                "data": enc_data,
                "enc": 1,
            }
            self.client.publish(ginfo["topic"], json.dumps(payload, ensure_ascii=False), qos=1)

            sys.stdout.write("\r  📤 Sent: " + str(i + 1) + "/" + str(total_chunks))
            sys.stdout.flush()

            time.sleep(0.05)

        sys.stdout.write("\n✅ File sent to group.\n> ")
        sys.stdout.flush()
        return True, ""
    except Exception as e:
        return False, str(e)

def _save_received_file(self, data, key):
    enc_data = data.get("data", "")
    filename = data.get("filename", "file")
    from_name = data.get("from_name", "?")
    size = data.get("size", 0)
    b64 = _decrypt_text(key, enc_data)
    if b64 is None:
        return
    try:
        file_bytes = base64.b64decode(b64)
    except Exception:
        return
    save_path = data.get("save_path", "").strip()
    if save_path:
        save_dir = os.path.expanduser(save_path)
        try:
            os.makedirs(save_dir, exist_ok=True)
        except Exception:
            if not ensure_file_dir():
                return
            save_dir = FILE_DIR
    else:
        if not ensure_file_dir():
            return
        save_dir = FILE_DIR
    filename = os.path.basename(filename)
    if not filename:
        filename = "file"
    self.pending_files.append({
        "from_name": from_name,
        "filename": filename,
        "size": size,
        "file_bytes": file_bytes,
        "save_dir": save_dir,
        "ts": now_short(),
    })
    sys.stdout.write(
        "\n📎 [FILE] from " + from_name + ": " + filename +
        " (" + str(size) + " bytes)\n"
        "    Accept? [Y] Yes  [N] No\n> "
    )
    sys.stdout.flush()

def _receive_friend_file(self, data):
    from_id = data.get("from_id", "")
    if not from_id:
        return
    is_friend = False
    for fname, fid in self.friends.items():
        if fid == from_id:
            is_friend = True
            break
    if not is_friend:
        return
    _save_received_file(self, data, _kdf_pair(self.my_id, from_id))

def _receive_group_file(self, data, gid):
    if data.get("from_id") == self.my_id:
        return
    _save_received_file(self, data, _kdf_group(gid))

def presence_label(last_ts, now=None):
    if not last_ts:
        return "○ offline"
    if now is None:
        now = now_ts()
    delta = now - last_ts
    if delta <= AWAY_TIMEOUT:
        return "● online"
    if delta <= PRESENCE_TIMEOUT:
        return "◐ away"
    return "○ offline"


def presence_short(last_ts):
    if not last_ts:
        return "○"
    delta = now_ts() - last_ts
    if delta <= AWAY_TIMEOUT:
        return "●"
    if delta <= PRESENCE_TIMEOUT:
        return "◐"
    return "○"


# ============================================================
# P2P CLIENT
# ============================================================

class P2PClient:
    def __init__(self, cfg):
        self.cfg = cfg
        self.username = cfg.get("username", "User")
        self.my_id = cfg.get("my_id", "")

        self.cfg.setdefault("friends", {})
        self.cfg.setdefault("pending_outgoing", {})
        self.cfg.setdefault("pending_incoming", {})
        self.cfg.setdefault("offline_queue", [])
        self.cfg.setdefault("last_seen", {})

        self.friends = self.cfg["friends"]
        self.pending_out = self.cfg["pending_outgoing"]
        self.pending_in = self.cfg["pending_incoming"]
        self.offline_queue = self.cfg["offline_queue"]
        self.last_seen = self.cfg["last_seen"]
        self.cfg.setdefault("groups", {})
        self.cfg.setdefault("pending_group_invites", {})

        self.groups = self.cfg["groups"]
        self.group_invites = self.cfg["pending_group_invites"]

        self.cfg.setdefault("pending_approvals", {})
        self.pending_approvals = self.cfg["pending_approvals"]

        self.cfg.setdefault("pending_transfers", {})
        self.pending_transfers = self.cfg["pending_transfers"]
        self.pending_results = {}
        self.pending_files = []

        self.client = None
        self.connected = False
        self.current_chat = None
        self.chat_logs = {}
        self.unread = {}

        self.lock = threading.Lock()
        self.running = True
        self._threads_started = False

    def save(self):
        self.cfg["friends"] = self.friends
        self.cfg["pending_outgoing"] = self.pending_out
        self.cfg["pending_incoming"] = self.pending_in
        self.cfg["offline_queue"] = self.offline_queue
        self.cfg["last_seen"] = self.last_seen
        self.cfg["groups"] = self.groups
        self.cfg["pending_group_invites"] = self.group_invites
        self.cfg["pending_approvals"] = self.pending_approvals
        self.cfg["pending_transfers"] = self.pending_transfers
        save_config(self.cfg)

    def _enc(self, other_id, text):
        try:
            return _encrypt_text(_kdf_pair(self.my_id, other_id), text)
        except Exception:
            return text

    def _dec(self, other_id, blob):
        try:
            return _decrypt_text(_kdf_pair(self.my_id, other_id), blob)
        except Exception:
            return None

    def _enc_g(self, gid, text):
        try:
            return _encrypt_text(_kdf_group(gid), text)
        except Exception:
            return text

    def _dec_g(self, gid, blob):
        try:
            return _decrypt_text(_kdf_group(gid), blob)
        except Exception:
            return None


    # --------------------------------------------------------
    # MQTT CONNECTION (v4.1 FIX)
    # --------------------------------------------------------
    def mqtt_connect(self):
        try:
            self.client = mqtt.Client(
                mqtt.CallbackAPIVersion.VERSION2,
                client_id="termux_ai_v4_" + self.my_id,
                clean_session=False,
            )
            self.client.on_connect = self._on_connect
            self.client.on_message = self._on_message
            self.client.on_disconnect = self._on_disconnect

            # CRITICAL: Auto-reconnect settings
            self.client.reconnect_delay_set(min_delay=1, max_delay=5)

            # Start network loop FIRST (in background)
            self.client.loop_start()

            # Use connect_async (won't give up on failure)
            try:
                self.client.connect_async(BROKER, PORT, KEEPALIVE)
            except Exception:
                pass

            # Brief wait for first connection
            print("  Connecting...")
            for _ in range(30):
                if self.connected:
                    return True
                time.sleep(0.1)

            # Not connected yet - will retry in background
            return False
        except Exception as e:
            print("  [ERROR] " + str(e))
            return False

    def mqtt_disconnect(self):
        self.running = False
        try:
            if self.client and self.connected:
                self.client.publish(
                    TOPIC_PRES + self.my_id,
                    json.dumps({"name": self.username, "my_id": self.my_id, "ts": 0}),
                    qos=0, retain=True
                )
        except Exception:
            pass
        try:
            if self.client:
                self.client.loop_stop()
                self.client.disconnect()
        except Exception:
            pass
        self.connected = False

    def _on_connect(
            self,
            client,
            userdata,
            flags,
            reason_code,
            properties=None):
        if reason_code == 0 or str(reason_code) == "Success":
            self.connected = True

            # Resubscribe (works on every reconnect)
            self.client.subscribe(TOPIC_MSG + self.my_id, qos=1)
            self.client.subscribe(TOPIC_REQ + self.my_id, qos=1)
            self.client.subscribe(TOPIC_CMD + self.my_id, qos=1)
            self.client.subscribe(TOPIC_CMDRES + self.my_id, qos=1)
            for name, fid in self.friends.items():
                self.client.subscribe(TOPIC_PRES + fid, qos=0)
            for gname, ginfo in self.groups.items():
                topic = ginfo.get("topic", "")
                if topic:
                    self.client.subscribe(topic, qos=1)

            # Start background threads only ONCE
            if not self._threads_started:
                self._threads_started = True
                threading.Thread(
                    target=self._presence_loop,
                    daemon=True).start()
                threading.Thread(
                    target=self._process_queue,
                    daemon=True).start()
                threading.Thread(
                    target=self._network_watchdog,
                    daemon=True).start()
                threading.Thread(
                    target=self._cleanup_transfers,
                    daemon=True).start()

            # Re-publish pending friend requests (recipient may have been
            # offline)
            threading.Thread(
                target=self._republish_pending_requests,
                daemon=True).start()

        else:
            self.connected = False

    def _on_disconnect(
            self,
            client,
            userdata,
            flags,
            reason_code,
            properties=None):
        self.connected = False

    def _on_message(self, client, userdata, msg):
        topic = msg.topic
        try:
            data = json.loads(msg.payload.decode("utf-8", "replace"))
        except Exception:
            return

        if topic.startswith(TOPIC_MSG):
            self._handle_msg(data)
        elif topic.startswith(TOPIC_REQ):
            self._handle_req(data)
        elif topic.startswith(TOPIC_PRES):
            self._handle_pres(topic, data)
        elif topic.startswith(TOPIC_CMD):
            self._handle_cmd_request(data)
        elif topic.startswith(TOPIC_CMDRES):
            self._handle_cmd_result(data)
        elif topic.startswith(TOPIC_GROUP):
            self._handle_group_msg(topic, data)

    # --------------------------------------------------------
    # HANDLERS
    # --------------------------------------------------------
    def _handle_file_meta(self, data, gid=None):
        from_id = data.get("from_id", "")
        if not from_id or from_id == self.my_id:
            return

        if gid is None:
            is_friend = any(fid == from_id for fid in self.friends.values())
            if not is_friend:
                return

        file_id = data.get("file_id", "")
        if not file_id:
            return

        with self.lock:
            self.pending_transfers[file_id] = {
                "from_id": from_id,
                "from_name": data.get("from_name", "?"),
                "filename": data.get("filename", "file"),
                "size": data.get("size", 0),
                "total_chunks": data.get("total_chunks", 0),
                "received_chunks": {},
                "save_path": data.get("save_path", ""),
                "ts": data.get("ts", now_short()),
                "started_at": now_ts(),
                "is_group": gid is not None,
                "gid": gid or "",
            }
            self.save()

        sys.stdout.write(
            "\n📎 [FILE] from " + data.get("from_name", "?") +
            ": " + data.get("filename", "?") +
            " (" + str(data.get("size", 0)) + " bytes, " +
            str(data.get("total_chunks", 0)) + " chunks)\n"
        )
        sys.stdout.flush()

    def _handle_file_chunk(self, data, gid=None):
        from_id = data.get("from_id", "")
        if not from_id or from_id == self.my_id:
            return

        file_id = data.get("file_id", "")
        if not file_id:
            return

        with self.lock:
            transfer = self.pending_transfers.get(file_id)
            if not transfer:
                return
            if transfer["from_id"] != from_id:
                return

            if transfer.get("is_group", False):
                if not gid or transfer.get("gid") != gid:
                    return
                b64 = self._dec_g(gid, data.get("data", ""))
            else:
                b64 = self._dec(from_id, data.get("data", ""))

            if b64 is None:
                return

            index = data.get("index", -1)
            if index < 0:
                return

            try:
                chunk_bytes = base64.b64decode(b64)
            except Exception:
                return

            transfer["received_chunks"][str(index)] = chunk_bytes

            received = len(transfer["received_chunks"])
            total = transfer["total_chunks"]

            sys.stdout.write(
                "\r  📥 Receiving: " + str(received) + "/" + str(total) + " chunks"
            )
            sys.stdout.flush()

            if received >= total:
                self._finalize_transfer(file_id, transfer)

    def _finalize_transfer(self, file_id, transfer):
        try:
            file_bytes = b""
            for i in range(transfer["total_chunks"]):
                chunk = transfer["received_chunks"].get(str(i))
                if chunk is None:
                    sys.stdout.write("\n❌ Missing chunk " + str(i) + "\n> ")
                    sys.stdout.flush()
                    del self.pending_transfers[file_id]
                    self.save()
                    return
                file_bytes += chunk

            save_dir = transfer["save_path"].strip()
            if save_dir:
                save_dir = os.path.expanduser(save_dir)
                try:
                    os.makedirs(save_dir, exist_ok=True)
                except Exception:
                    save_dir = ensure_file_dir() or FILE_DIR
            else:
                save_dir = ensure_file_dir() or FILE_DIR

            self.pending_files.append({
                "from_name": transfer["from_name"],
                "filename": transfer["filename"],
                "size": transfer["size"],
                "file_bytes": file_bytes,
                "save_dir": save_dir,
                "ts": transfer["ts"],
            })

            del self.pending_transfers[file_id]
            self.save()

            sys.stdout.write(
                "\n📎 [FILE] from " + transfer["from_name"] +
                ": " + transfer["filename"] +
                " (" + str(transfer["size"]) + " bytes)\n" +
                "    Accept? [Y] Yes  [N] No\n> "
            )
            sys.stdout.flush()

        except Exception as e:
            sys.stdout.write("\n❌ Transfer error: " + str(e) + "\n> ")
            sys.stdout.flush()

    def _cleanup_transfers(self):
        while self.running:
            time.sleep(30)
            try:
                now = now_ts()
                with self.lock:
                    expired = []
                    for fid, t in self.pending_transfers.items():
                        if now - t.get("started_at", 0) > TRANSFER_TIMEOUT:
                            expired.append(fid)
                    for fid in expired:
                        del self.pending_transfers[fid]
                    if expired:
                        self.save()
            except Exception:
                pass
    def _handle_msg(self, data):
        msg_type = data.get("type", "")
        if msg_type == "file":
            _receive_friend_file(self, data)
            return
        if msg_type == "file_meta":
            self._handle_file_meta(data)
            return
        if msg_type == "file_chunk":
            self._handle_file_chunk(data)
            return
        from_id = data.get("from_id", "")
        from_name = data.get("from_name", "?")
        text = data.get("text", "")
        ts = data.get("ts", now_short())
        if data.get("enc") == 1:
            _d = self._dec(from_id, text)
            text = _d if _d is not None else "[unable to decrypt]"

        if not from_id or not text:
            return

        sender_key = None
        for name, fid in self.friends.items():
            if fid == from_id:
                sender_key = name
                break
        if sender_key is None:
            return

        self.last_seen[sender_key] = now_ts()

        with self.lock:
            if self.current_chat == sender_key:
                sys.stdout.write(
                    "\n[" + ts + "] " + from_name + ": " + text + "\n> ")
                sys.stdout.flush()
                self._log(sender_key, from_name, text, ts)
            else:
                self.unread[sender_key] = self.unread.get(sender_key, 0) + 1
                sys.stdout.write("\n📩 [" +
                                 from_name +
                                 "] " +
                                 text +
                                 "  (" +
                                 str(self.unread[sender_key]) +
                                 " new)\n> ")
                sys.stdout.flush()
                self._log(sender_key, from_name, text, ts)
            self.save()

    def _handle_req(self, data):
        action = data.get("action", "")
        from_id = data.get("from_id", "")
        from_name = data.get("from_name", "?")
        if not from_id:
            return

        if action == "request":
            with self.lock:
                self.pending_in[from_name] = {
                    "id": from_id,
                    "received_at": now_full(),
                }
                self.save()
                sys.stdout.write(
                    "\n🔔 [Request] " +
                    from_name +
                    " wants to be your friend. Use /requests\n> ")
                sys.stdout.flush()

        elif action == "accept":
            with self.lock:
                for name, info in list(self.pending_out.items()):
                    if info.get("id") == from_id:
                        del self.pending_out[name]
                        break
                self.friends[from_name.lower()] = from_id
                self.client.subscribe(TOPIC_PRES + from_id, qos=0)
                self.save()
                sys.stdout.write(
                    "\n✅ [Accepted] " +
                    from_name +
                    " accepted your request!\n> ")
                sys.stdout.flush()

        elif action == "reject":
            with self.lock:
                for name, info in list(self.pending_out.items()):
                    if info.get("id") == from_id:
                        del self.pending_out[name]
                        break

                self.save()
                sys.stdout.write(
                    "\n❌ [Rejected] " +
                    from_name +
                    " rejected your request.\n> ")
                sys.stdout.flush()

        elif action == "group_invite":
            self._handle_group_invite(data)

    def _handle_pres(self, topic, data):
        ts = int(data.get("ts", 0))
        fid = topic[len(TOPIC_PRES):]
        if not fid:
            return
        for friend_name, friend_id in self.friends.items():
            if friend_id == fid:
                if ts == 0:
                    self.last_seen[friend_name] = 0
                else:
                    self.last_seen[friend_name] = ts
                return


    def _handle_group_msg(self, topic, data):
        gid = topic[len(TOPIC_GROUP):]
        if not gid:
            return
        group_name = None
        for gname, ginfo in self.groups.items():
            if ginfo.get("id") == gid:
                group_name = gname
                break
        if not group_name:
            return

        # Handle sync messages
        msg_type = data.get("type", "")
        if msg_type == "file":
            _receive_group_file(self, data, gid)
            return
        if msg_type == "file_meta":
            self._handle_file_meta(data, gid)
            return
        if msg_type == "file_chunk":
            self._handle_file_chunk(data, gid)
            return
        if msg_type == "group_join":
            j_id = data.get("from_id", "")
            j_name = data.get("from_name", "?")
            if j_id and j_id != self.my_id:
                with self.lock:
                    members = self.groups[group_name].get("members", {})
                    if j_id not in members:
                        members[j_id] = j_name
                        self.groups[group_name]["members"] = members
                        self.save()
                        sys.stdout.write("\n[Group] " + j_name + " joined " + group_name + "\n> ")
                        sys.stdout.flush()
                self._group_member_here(group_name)
            return

        if msg_type == "group_leave":
            l_id = data.get("from_id", "")
            l_name = data.get("from_name", "?")
            if l_id and l_id != self.my_id:
                with self.lock:
                    members = self.groups[group_name].get("members", {})
                    if l_id in members:
                        del members[l_id]
                        self.groups[group_name]["members"] = members
                        self.save()
                        sys.stdout.write("\n[Group] " + l_name + " left " + group_name + "\n> ")
                        sys.stdout.flush()
            return

        if msg_type == "group_member":
            m_id = data.get("from_id", "")
            m_name = data.get("from_name", "?")
            if m_id and m_id != self.my_id:
                with self.lock:
                    members = self.groups[group_name].get("members", {})
                    if m_id not in members:
                        members[m_id] = m_name
                        self.groups[group_name]["members"] = members
                        self.save()
            return

        if msg_type == "group_kick":
            kicked_id = data.get("kicked_id", "")
            kicked_name = data.get("kicked_name", "?")
            if not kicked_id:
                return
            if kicked_id == self.my_id:
                ginfo = self.groups.get(group_name)
                if ginfo:
                    topic2 = ginfo.get("topic", "")
                    if topic2:
                        try:
                            self.client.unsubscribe(topic2)
                        except Exception:
                            pass
                    del self.groups[group_name]
                    self.save()
                sys.stdout.write("\n[Group] You were kicked from: " + group_name + "\n> ")
                sys.stdout.flush()
            else:
                with self.lock:
                    members = self.groups[group_name].get("members", {})
                    if kicked_id in members:
                        del members[kicked_id]
                        self.groups[group_name]["members"] = members
                        self.save()
                        sys.stdout.write("\n[Group] " + kicked_name + " was kicked from " + group_name + "\n> ")
                        sys.stdout.flush()
            return

        if msg_type == "group_delete":
            from_name2 = data.get("from_name", "?")
            with self.lock:
                ginfo = self.groups.get(group_name)
                if ginfo:
                    topic2 = ginfo.get("topic", "")
                    if topic2:
                        try:
                            self.client.unsubscribe(topic2)
                        except Exception:
                            pass
                    del self.groups[group_name]
                    self.save()
                sys.stdout.write("\n[Group] " + from_name2 + " deleted group: " + group_name + "\n> ")
                sys.stdout.flush()
            return

        if msg_type == "group_rename":
            old_name = data.get("old_name", "")
            new_name = data.get("new_name", "")
            if not old_name or not new_name:
                return
            with self.lock:
                ginfo = self.groups.get(old_name)
                if ginfo:
                    del self.groups[old_name]
                    ginfo["name"] = new_name
                    self.groups[new_name] = ginfo
                    self.save()
                    sys.stdout.write("\n[Group] Renamed: " + old_name + " -> " + new_name + "\n> ")
                    sys.stdout.flush()
            return

        from_id = data.get("from_id", "")
        from_name = data.get("from_name", "?")
        text = data.get("text", "")
        ts = data.get("ts", now_short())
        if data.get("enc") == 1:
            _d = self._dec_g(gid, text)
            text = _d if _d is not None else "[unable to decrypt]"
        if not from_id or not text:
            return
        if from_id == self.my_id:
            return
        with self.lock:
            if self.current_chat == "G:" + group_name:
                sys.stdout.write("\n[" + ts + "] " + from_name + ": " + text + "\n> ")
                sys.stdout.flush()
            else:
                key = "G:" + group_name
                self.unread[key] = self.unread.get(key, 0) + 1
                sys.stdout.write("\n📩 [@" + group_name + "] " + from_name + ": " + text + "  (" + str(self.unread[key]) + " new)\n> ")
                sys.stdout.flush()
                self._log("group_" + group_name, from_name, text, ts)

    def _handle_group_invite(self, data):
        gid = data.get("group_id", "")
        gname = data.get("group_name", "")
        from_id = data.get("from_id", "")
        from_name = data.get("from_name", "?")
        topic = data.get("topic", "")
        if not gid or not gname or not topic:
            return
        with self.lock:
            self.group_invites[gname] = {
                "id": gid,
                "topic": topic,
                "owner_id": from_id,
                "owner_name": from_name,
                "invited_at": now_full(),
            }
            self.save()
        sys.stdout.write("\n🔔 [Group Invite] " + from_name + " invited you to: " + gname + "\n   Use /accept_group " + gname + " or /reject_group " + gname + "\n> ")
        sys.stdout.flush()

    def _handle_cmd_request(self, data):
        from_id = data.get("from_id", "")
        from_name = data.get("from_name", "?")
        cmd_text = data.get("cmd", "")
        if data.get("enc") == 1:
            _d = self._dec(from_id, cmd_text)
            cmd_text = _d if _d is not None else "[unable to decrypt]"
        req_id = data.get("req_id", "")
        ts = data.get("ts", now_short())
        if not from_id or not cmd_text or not req_id:
            return
        is_friend = False
        for fname, fid in self.friends.items():
            if fid == from_id:
                is_friend = True
                break
        if not is_friend:
            return
        with self.lock:
            self.pending_approvals[req_id] = {
                "from_id": from_id,
                "from_name": from_name,
                "cmd": cmd_text,
                "ts": ts,
            }
            self.save()
        sys.stdout.write(
            "\n🔔 [CMD] " + from_name + " wants to run:\n"
            "    " + cmd_text + "\n"
            "    Send Y to approve, N to reject\n> "
        )
        sys.stdout.flush()

    def _handle_cmd_result(self, data):
        req_id = data.get("req_id", "")
        from_name = data.get("from_name", "?")
        output = data.get("output", "")
        if data.get("enc") == 1:
           _d = self._dec(data.get("from_id", ""), output)
           output = _d if _d is not None else "[unable to decrypt]"
        exit_code = data.get("exit_code", 0)
        if not req_id:
            return
        if req_id in self.pending_results:
            del self.pending_results[req_id]
        sys.stdout.write("\n📋 [CMD Result] from " + from_name + ":\n")
        if output.strip():
            sys.stdout.write(output)
            if not output.endswith("\n"):
                sys.stdout.write("\n")
        else:
            sys.stdout.write("No Output\n")
        sys.stdout.write("Exit code: " + str(exit_code) + "\n> ")
        sys.stdout.flush()


    def _group_member_here(self, group_name):
        ginfo = self.groups.get(group_name)
        if not ginfo:
            return
        payload = {
            "type": "group_member",
            "from_id": self.my_id,
            "from_name": self.username,
            "ts": now_short(),
        }
        try:
            self.client.publish(
                ginfo["topic"],
                json.dumps(payload, ensure_ascii=False),
                qos=1,
            )
        except Exception:
            pass


    # --------------------------------------------------------
    # BACKGROUND LOOPS (v4.1: don't require connected in while)
    # --------------------------------------------------------
    def _presence_loop(self):
        while self.running:
            try:
                if self.connected:
                    payload = json.dumps({
                        "name": self.username,
                        "my_id": self.my_id,
                        "ts": now_ts(),
                    }, ensure_ascii=False)
                    self.client.publish(
                        TOPIC_PRES + self.my_id, payload, qos=0, retain=True)
                    self.last_seen["__self__"] = now_ts()
            except Exception:
                pass
            time.sleep(PRESENCE_INTERVAL)

    def _process_queue(self):
        time.sleep(2)
        while self.running:
            if not self.connected:
                time.sleep(2)
                continue

            with self.lock:
                if not self.offline_queue:
                    time.sleep(1)
                    continue
                item = self.offline_queue.pop(0)

            to = item.get("to", "")
            text = item.get("text", "")
            if to in self.friends and text:
                ok, err = self._send_raw(to, text)
                if ok:
                    sys.stdout.write(
                        "\n📤 [Queued->Sent] to " + to + ": " + text + "\n> ")
                    sys.stdout.flush()
                    self.save()
                else:
                    self.offline_queue.insert(0, item)
                    time.sleep(2)
            else:
                self.save()
            time.sleep(0.3)

    def _network_watchdog(self):
        """Aggressively detect offline and force reconnect."""
        time.sleep(2)
        while self.running:
            try:
                if not self.connected:
                    # Try to force a reconnect
                    try:
                        self.client.reconnect()
                    except Exception:
                        pass
            except Exception:
                pass
            time.sleep(NETWORK_CHECK_INTERVAL)

    def _republish_pending_requests(self):
        """Re-send friend requests that haven't been accepted yet."""
        time.sleep(2)
        if not self.connected:
            return
        with self.lock:
            pending = list(self.pending_out.items())
        for name, info in pending:
            fid = info.get("id", "")
            if not fid:
                continue
            try:
                self.send_request(name, fid)
            except Exception:
                pass
            time.sleep(0.4)

    # --------------------------------------------------------
    # SENDING
    # --------------------------------------------------------
    def _send_raw(self, friend_name, text):
        if not self.connected:
            return False, "offline"
        fid = self.friends.get(friend_name)
        if not fid:
            return False, "unknown friend"
        payload = {
            "from_id": self.my_id,
            "from_name": self.username,
            "text": self._enc(fid, text),
            "enc": 1,
            "ts": now_short(),
        }
        try:
            self.client.publish(
                TOPIC_MSG + fid,
                json.dumps(payload, ensure_ascii=False),
                qos=1,
            )
            return True, ""
        except Exception as e:
            return False, str(e)

    def send_message(self, friend_name, text):
        ok, err = self._send_raw(friend_name, text)
        if not ok:
            with self.lock:
                self.offline_queue.append({
                    "to": friend_name,
                    "text": text,
                    "ts": now_full(),
                })
                self.save()
            return False, "queued"
        return True, ""

    def send_request(self, friend_name, friend_id):
        if not self.connected:
            return False
        payload = {
            "from_id": self.my_id,
            "from_name": self.username,
            "action": "request",
        }
        try:
            self.client.publish(
                TOPIC_REQ + friend_id,
                json.dumps(payload, ensure_ascii=False),
                qos=1,
            )
            return True
        except Exception:
            return False

    def send_accept(self, friend_name, friend_id):
        payload = {
            "from_id": self.my_id,
            "from_name": self.username,
            "action": "accept",
        }
        try:
            self.client.publish(
                TOPIC_REQ + friend_id,
                json.dumps(payload, ensure_ascii=False),
                qos=1,
            )
            self.friends[friend_name.lower()] = friend_id
            self.client.subscribe(TOPIC_PRES + friend_id, qos=0)
            self.save()
            return True
        except Exception:
            return False

    def send_reject(self, friend_name, friend_id):
        payload = {
            "from_id": self.my_id,
            "from_name": self.username,
            "action": "reject",
        }
        try:
            self.client.publish(
                TOPIC_REQ + friend_id,
                json.dumps(payload, ensure_ascii=False),
                qos=1,
            )
            return True
        except Exception:
            return False


    def group_create(self, group_name):
        gname = group_name.strip().lower()
        if not gname:
            return None, "Empty name"
        if gname in self.groups:
            return None, "Group already exists"
        gid = "GRP_" + gen_suffix(8)
        topic = TOPIC_GROUP + gid
        self.groups[gname] = {
            "id": gid,
            "name": gname,
            "owner": self.my_id,
            "members": {
                self.my_id: self.username,
            },
            "topic": topic,
            "created": now_full(),
        }
        self.client.subscribe(topic, qos=1)
        self.save()
        return gid, None

    def group_invite(self, group_name, friend_name, friend_id=None):
        gname = group_name.strip().lower()
        fname = friend_name.strip().lower()
        if gname not in self.groups:
            return False, "No group with this name"
        if friend_id:
            fid = friend_id.strip().upper()
        else:
            if fname not in self.friends:
                return False, "Not a friend (specify ID)"
            fid = self.friends[fname]
        ginfo = self.groups[gname]
        if fid in ginfo["members"]:
            return False, "Already a member"
        payload = {
            "from_id": self.my_id,
            "from_name": self.username,
            "action": "group_invite",
            "group_id": ginfo["id"],
            "group_name": gname,
            "topic": ginfo["topic"],
        }
        try:
            self.client.publish(
                TOPIC_REQ + fid,
                json.dumps(payload, ensure_ascii=False),
                qos=1,
            )
            return True, ""
        except Exception as e:
            return False, str(e)

    def group_accept(self, group_name):
        gname = group_name.strip().lower()
        if gname not in self.group_invites:
            return False, "No invitation found"
        info = self.group_invites[gname]
        self.groups[gname] = {
            "id": info["id"],
            "name": gname,
            "owner": info["owner_id"],
            "members": {
                self.my_id: self.username,
                info["owner_id"]: info["owner_name"],
            },
            "topic": info["topic"],
            "created": now_full(),
        }
        del self.group_invites[gname]
        self.client.subscribe(info["topic"], qos=1)
        self.save()

        # Notify all members that we joined
        payload = {
            "type": "group_join",
            "from_id": self.my_id,
            "from_name": self.username,
            "group_id": info["id"],
            "group_name": gname,
            "ts": now_short(),
        }
        try:
            self.client.publish(
                info["topic"],
                json.dumps(payload, ensure_ascii=False),
                qos=1,
            )
        except Exception:
            pass

        return True, ""

    def group_reject(self, group_name):
        gname = group_name.strip().lower()
        if gname not in self.group_invites:
            return False, "No invitation found"
        del self.group_invites[gname]
        self.save()
        return True, ""

    def group_leave(self, group_name):
        gname = group_name.strip().lower()
        if gname not in self.groups:
            return False, "Group not found"
        ginfo = self.groups[gname]
        topic = ginfo.get("topic", "")
        if topic:
            # Notify others before leaving
            leave_payload = {
                "type": "group_leave",
                "from_id": self.my_id,
                "from_name": self.username,
                "ts": now_short(),
            }
            try:
                self.client.publish(
                    topic,
                    json.dumps(leave_payload, ensure_ascii=False),
                    qos=1,
                )
                time.sleep(0.5)
            except Exception:
                pass
            try:
                self.client.unsubscribe(topic)
            except Exception:
                pass
        del self.groups[gname]
        self.save()
        return True, ""

    def group_send(self, group_name, text):
        gname = group_name.strip().lower()
        if gname not in self.groups:
            return False, "Group not found"
        ginfo = self.groups[gname]
        payload = {
            "from_id": self.my_id,
            "from_name": self.username,
            "text": self._enc_g(ginfo["id"], text),
            "enc": 1,
            "ts": now_short(),
        }
        try:
            self.client.publish(
                ginfo["topic"],
                json.dumps(payload, ensure_ascii=False),
                qos=1,
            )
            return True, ""
        except Exception as e:
            return False, str(e)

    def group_kick(self, group_name, member_name):
        gname = group_name.strip().lower()
        mname = member_name.strip().lower()
        if gname not in self.groups:
            return False, "Group not found"
        ginfo = self.groups[gname]
        if ginfo.get("owner") != self.my_id:
            return False, "You are not the owner"
        if mname == self.username.lower():
            return False, "You cannot kick yourself"
        target_id = None
        for mid, name in ginfo["members"].items():
            if name.lower() == mname:
                target_id = mid
                break
        if not target_id:
            return False, "Member not found"
        payload = {
            "type": "group_kick",
            "kicked_id": target_id,
            "kicked_name": mname,
            "from_id": self.my_id,
            "from_name": self.username,
            "ts": now_short(),
        }
        try:
            self.client.publish(
                ginfo["topic"],
                json.dumps(payload, ensure_ascii=False),
                qos=1,
            )
            del ginfo["members"][target_id]
            self.save()
            return True, ""
        except Exception as e:
            return False, str(e)

    def group_rename(self, old_name, new_name):
        oname = old_name.strip().lower()
        nname = new_name.strip().lower()
        if oname not in self.groups:
            return False, "Group not found"
        if not nname:
            return False, "New name is empty"
        if nname in self.groups:
            return False, "A group with this name already exists"
        ginfo = self.groups[oname]
        if ginfo.get("owner") != self.my_id:
            return False, ""
        payload = {
            "type": "group_rename",
            "old_name": oname,
            "new_name": nname,
            "from_id": self.my_id,
            "from_name": self.username,
            "ts": now_short(),
        }
        try:
            self.client.publish(
                ginfo["topic"],
                json.dumps(payload, ensure_ascii=False),
                qos=1,
            )
            del self.groups[oname]
            ginfo["name"] = nname
            self.groups[nname] = ginfo
            self.save()
            return True, ""
        except Exception as e:
            return False, str(e)

    def group_delete(self, group_name):
        gname = group_name.strip().lower()
        if gname not in self.groups:
            return False, "Group not found"
        ginfo = self.groups[gname]
        if ginfo.get("owner") != self.my_id:
            return False, "You are not the owner"
        payload = {
            "type": "group_delete",
            "from_id": self.my_id,
            "from_name": self.username,
            "ts": now_short(),
        }
        try:
            self.client.publish(
                ginfo["topic"],
                json.dumps(payload, ensure_ascii=False),
                qos=1,
            )
            topic = ginfo.get("topic", "")
            if topic:
                try:
                    self.client.unsubscribe(topic)
                except Exception:
                    pass
            del self.groups[gname]
            self.save()
            return True, ""
        except Exception as e:
            return False, str(e)


    def send_cmd(self, friend_name, cmd_text):
        fid = self.friends.get(friend_name)
        if not fid:
            return False, "unknown friend", ""
        if not self.connected:
            return False, "offline", ""
        req_id = "REQ_" + gen_suffix(6)
        payload = {
            "from_id": self.my_id,
            "from_name": self.username,
            "cmd": self._enc(fid, cmd_text),
            "enc": 1,
            "req_id": req_id,
            "ts": now_short(),
        }
        try:
            self.client.publish(
                TOPIC_CMD + fid,
                json.dumps(payload, ensure_ascii=False),
                qos=1,
            )
            self.pending_results[req_id] = {
                "to": friend_name,
                "cmd": cmd_text,
                "ts": now_full(),
            }
            return True, "", req_id
        except Exception as e:
            return False, str(e), ""

    def approve_cmd(self, req_id):
        with self.lock:
            info = self.pending_approvals.get(req_id)
            if not info:
                return False, "not found"
            del self.pending_approvals[req_id]
            self.save()
        output = ""
        exit_code = 0
        try:
            result = subprocess.run(
                info["cmd"],
                shell=True,
                capture_output=True,
                text=True,
                timeout=30,
            )
            output = (result.stdout or "") + (result.stderr or "")
            exit_code = result.returncode
        except subprocess.TimeoutExpired:
            output = "[TIMEOUT: exceeded 30 seconds]"
            exit_code = -1
        except Exception as e:
            output = "[ERROR: " + str(e) + "]"
            exit_code = -1
        if len(output) > 5000:
            output = output[:5000] + "\n...[truncated]"
        payload = {
            "from_id": self.my_id,
            "from_name": self.username,
            "req_id": req_id,
            "output": self._enc(info["from_id"], output),
            "enc": 1,
            "exit_code": exit_code,
            "ts": now_short(),
        }
        try:
            self.client.publish(
                TOPIC_CMDRES + info["from_id"],
                json.dumps(payload, ensure_ascii=False),
                qos=1,
            )
        except Exception:
            pass
        return True, output

    def reject_cmd(self, req_id):
        with self.lock:
            if req_id in self.pending_approvals:
                del self.pending_approvals[req_id]
                self.save()
                return True
        return False


    # --------------------------------------------------------
    # LOGGING
    # --------------------------------------------------------
    def _log(self, friend_key, sender_name, text, ts):
        if friend_key not in self.chat_logs:
            if not ensure_log_dir():
                return
            filename = "chat_" + friend_key + "_" + now_filename() + ".txt"
            path = os.path.join(CHAT_LOG_DIR, filename)
            try:
                with open(path, "w", encoding="utf-8") as f:
                    f.write("=" * 55 + "\n")
                    f.write("Termux AI P2P Chat v" + VERSION + "\n")
                    f.write("Started: " + now_full() + "\n")
                    f.write("With: " + friend_key + "\n")
                    f.write("=" * 55 + "\n\n")
                self.chat_logs[friend_key] = path
            except Exception:
                return
        try:
            with open(self.chat_logs[friend_key], "a", encoding="utf-8") as f:
                f.write("[" + ts + "] " + sender_name + ": " + text + "\n")
        except Exception:
            pass


# ============================================================
# UI HELPERS
# ============================================================

def print_help():
    print()
    print("=" * 55)
    print("  COMMANDS")
    print("=" * 55)
    print()
    print("  /me                  Show your ID")
    print("  /add NAME [ID]       Send friend request")
    print("  /friends             List friends + status")
    print("  /requests            Show pending requests")
    print("  /accept NAME         Accept friend request")
    print("  /reject NAME         Reject friend request")
    print("  /remove NAME         Remove friend")
    print("  /chat NAME           Open chat")
    print("  /queue               Show offline queue")
    print("  /cmd FRIEND CMD      Send terminal command to friend")
    print("  /file FRIEND PATH    Send file to friend (max 64KB)")
    print("  /fileg GROUP PATH    Send file to group (max 64KB)")
    print("  /approve [REQ_ID]    Approve and execute")
    print("  /reject [REQ_ID]     Reject command")
    print("  /group               Groups menu")
    print("  /group create NAME   Create group")
    print("  /group invite G F    Invite friend to group")
    print("  /group list          List your groups")
    print("  /group kick G N      Kick member (owner)")
    print("  /group rename O N    Rename group (owner)")
    print("  /group delete NAME   Delete group (owner)")
    print("  /group info NAME     Show group info")
    print("  /accept_group NAME   Accept group invite")
    print("  /reject_group NAME   Reject group invite")
    print("  /g NAME              Open group chat")
    print("  /emoji               Show emoji shortcuts")
    print("  /help                This help")
    print("  /quit                Exit")
    print()
    print("  In a chat:")
    print("    /back              Back to menu")
    print("    /quit              Exit")
    print("    /history           Show last 50 messages")
    print("    /search TERM       Search in history")
    print("    /clear             Clear screen")
    print("    /me                Show your ID")
    print()


def show_me(client):
    clear()
    print("=" * 55)
    print("  YOUR PERMANENT ID")
    print("=" * 55)
    print()
    print("  Username: " + client.username)
    print()
    print("      " + client.my_id)
    print()
    print("=" * 55)
    print()
    print("  Share this with friends.")
    print("  They will use: /add YOUR_NAME " + client.my_id)
    print()
    input("  Press ENTER...")


def show_friends(client):
    clear()
    print("=" * 55)
    print("  FRIENDS (" + str(len(client.friends)) + ")")
    print("=" * 55)
    print()
    if not client.friends:
        print("  No friends yet.")
        print()
        print("  Use /add to send a request.")
    else:
        now = now_ts()
        for i, (name, fid) in enumerate(client.friends.items(), 1):
            ls = client.last_seen.get(name, 0)
            st = presence_label(ls, now)
            unread = client.unread.get(name, 0)
            unread_str = " (" + str(unread) + " new)" if unread else ""
            print("  " + str(i) + ". " + name + "  " + st + unread_str)
            print("     " + fid)
            print()
    print("=" * 55)
    print()
    input("  Press ENTER...")


def show_requests(client):
    clear()
    print("=" * 55)
    print("  PENDING FRIEND REQUESTS")
    print("=" * 55)
    print()
    if not client.pending_in:
        print("  No pending requests.")
    else:
        for i, (name, info) in enumerate(client.pending_in.items(), 1):
            print("  " + str(i) + ". " + name)
            print("     ID: " + info.get("id", "?"))
            print("     At: " + info.get("received_at", "?"))
            print()
        print("  Commands:")
        print("    /accept NAME")
        print("    /reject NAME")
    print()
    input("  Press ENTER...")


def show_queue(client):
    clear()
    print("=" * 55)
    print("  OFFLINE QUEUE (" + str(len(client.offline_queue)) + ")")
    print("=" * 55)
    print()
    if not client.offline_queue:
        print("  Empty. All messages sent.")
    else:
        for i, item in enumerate(client.offline_queue, 1):
            print("  " + str(i) + ". -> " + item.get("to", "?"))
            print("     " + item.get("text", "")[:50])
            print("     " + item.get("ts", "?"))
            print()
        print("  These will send when online.")
    print()
    input("  Press ENTER...")


# ============================================================
# ACTIONS
# ============================================================

def action_add(client, parts):
    if len(parts) < 2:
        print()
        print("[!] Usage: /add NAME [ID]")
        print()
        return False
    name = parts[1].strip().lower()
    if not name:
        print("[!] Invalid name.")
        return False
    if len(parts) >= 3:
        fid = parts[2].strip().upper()
    else:
        try:
            fid = input("  Friend's ID: ").strip().upper()
        except (EOFError, KeyboardInterrupt):
            return False
    if not fid:
        print("[!] ID required.")
        return False
    if fid == client.my_id:
        print("[!] That's your own ID!")
        return False
    if name in client.friends:
        print("[!] Already a friend: " + name)
        return False
    if name in client.pending_out:
        print("[?] Already sent a request to " + name + ".")
        return False
    if not client.connected:
        print("[!] Not connected. Wait for connection.")
        return False
    ok = client.send_request(name, fid)
    if ok:
        client.pending_out[name] = {"id": fid, "sent_at": now_full()}
        client.save()
        print()
        print("[OK] Request sent to " + name)
        print("     Waiting for approval...")
        return True
    else:
        print("[ERROR] Failed to send.")
        return False


def action_accept(client, parts):
    if len(parts) < 2:
        print("[!] Usage: /accept NAME")
        return False
    name = parts[1].strip().lower()
    if name not in client.pending_in:
        print("[!] No request from: " + name)
        return False
    info = client.pending_in[name]
    fid = info["id"]
    ok = client.send_accept(name, fid)
    if ok:
        del client.pending_in[name]
        client.save()
        print("[OK] Accepted: " + name)
        print("     " + fid)
        return True
    else:
        print("[ERROR] Failed.")
        return False


def action_reject(client, parts):
    if len(parts) < 2:
        print("[!] Usage: /reject NAME")
        return False
    name = parts[1].strip().lower()
    if name not in client.pending_in:
        print("[!] No request from: " + name)
        return False
    info = client.pending_in[name]
    client.send_reject(name, info["id"])
    del client.pending_in[name]
    client.save()
    print("[OK] Rejected: " + name)
    return True


def action_remove(client, parts):
    if len(parts) < 2:
        print("[!] Usage: /remove NAME")
        return False
    name = parts[1].strip().lower()
    if name not in client.friends:
        print("[!] Not found.")
        return False
    try:
        ans = input("  Remove " + name + "? (y/N): ").strip().lower()
    except (EOFError, KeyboardInterrupt):
        return False
    if ans != "y":
        print("[Cancelled]")
        return False
    del client.friends[name]
    client.unread.pop(name, None)
    client.save()
    print("[OK] Removed: " + name)
    return True


# ============================================================
# CHAT MODE
# ============================================================

def get_chat_log_path(client, friend_key):
    """Find the most recent log file for a friend."""
    if friend_key in client.chat_logs:
        return client.chat_logs[friend_key]
    if not os.path.isdir(CHAT_LOG_DIR):
        return None
    prefix = "chat_" + friend_key + "_"
    matches = []
    try:
        for fname in os.listdir(CHAT_LOG_DIR):
            if fname.startswith(prefix) and fname.endswith(".txt"):
                matches.append(os.path.join(CHAT_LOG_DIR, fname))
    except Exception:
        return None
    if not matches:
        return None
    matches.sort()
    return matches[-1]


def show_history(client, friend_key, n=50):
    path = get_chat_log_path(client, friend_key)
    if not path or not os.path.exists(path):
        print()
        print("[!] No history for this friend yet.")
        return
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except Exception as e:
        print("[!] Cannot read: " + str(e))
        return
    msgs = [l.rstrip() for l in lines if l.startswith("[")]
    if not msgs:
        print("[!] History is empty.")
        return
    tail = msgs[-n:]
    print()
    print("=" * 55)
    print("  HISTORY (last " + str(len(tail)) + " of " + str(len(msgs)) + ")")
    print("=" * 55)
    for l in tail:
        print(l)
    print("=" * 55)


def search_history(client, friend_key, term):
    if not term:
        print("[!] Usage: /search TERM")
        return
    path = get_chat_log_path(client, friend_key)
    if not path or not os.path.exists(path):
        print("[!] No history.")
        return
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except Exception as e:
        print("[!] Cannot read: " + str(e))
        return
    needle = term.lower()
    matches = []
    for l in lines:
        if l.startswith("[") and needle in l.lower():
            matches.append(l.rstrip())
    print()
    print("=" * 55)
    print("  SEARCH: " + term + " (" + str(len(matches)) + " matches)")
    print("=" * 55)
    if not matches:
        print("  No matches found.")
    else:
        for l in matches[-50:]:
            print(l)
    print("=" * 55)


def chat_mode(client, friend_name):
    friend_name = friend_name.strip().lower()
    if friend_name not in client.friends:
        print()
        print("[!] Unknown friend: " + friend_name)
        input("  Press ENTER...")
        return None

    fid = client.friends[friend_name]
    client.unread[friend_name] = 0

    clear()
    print("=" * 55)
    print("  CHAT WITH: " + friend_name)
    print("=" * 55)
    print()
    ls = client.last_seen.get(friend_name, 0)
    print("  Status:  " + presence_label(ls))
    print("  Friend:  " + fid)
    print("  You:     " + client.my_id)
    print()
    print("  /back to return, /quit to exit, /help for commands")
    print("=" * 55)
    print()

    with client.lock:
        client.current_chat = friend_name

    try:
        while True:
            try:
                msg = input("> ")
            except (EOFError, KeyboardInterrupt):
                break
            stripped = msg.strip()
            if not stripped:
                continue

            if stripped.startswith("/"):
                parts = stripped.split(" ", 1)
                cmd = parts[0].lower()
                if cmd in ("/back", "/exit"):
                    break
                elif cmd == "/quit":
                    with client.lock:
                        client.current_chat = None
                    return "quit"
                elif cmd == "/help":
                    print_help()
                    continue
                elif cmd == "/me":
                    print("  " + client.my_id)
                    continue
                elif cmd == "/history":
                    show_history(client, friend_name, 50)
                    continue
                elif cmd == "/search":
                    if len(parts) > 1:
                        search_history(client, friend_name, parts[1])
                    else:
                        print("[!] Usage: /search TERM")
                    continue
                elif cmd == "/clear":
                    clear()
                    print("=" * 55)
                    print("  CHAT WITH: " + friend_name)
                    print("=" * 55)
                    print()
                    continue
                else:
                    print("[!] Unknown. /help")
                    continue

            processed = apply_emoji(stripped)
            ok, err = client.send_message(friend_name, processed)
            ts = now_short()
            if ok:
                print("[" + ts + "] You: " + processed)
                client._log(friend_name, "You", processed, ts)
            else:
                print("[" + ts + "] You (queued): " + processed)
                client._log(friend_name, "You (queued)", processed, ts)

    finally:
        with client.lock:
            client.current_chat = None

    return None

# ============================================================
# FIRST RUN
# ============================================================


def first_run():
    clear()
    print("=" * 55)
    print("  WELCOME TO TERMUX AI P2P CHAT v" + VERSION)
    print("=" * 55)
    print()
    print("  First time setup.")
    print()
    print("  Username (max 20 chars):")
    print()

    username = ""
    while not username:
        try:
            name = input("  Username: ").strip()
        except (EOFError, KeyboardInterrupt):
            return None
        if not name:
            print("  [!] Empty.")
            continue
        if len(name) > 20:
            print("  [!] Too long.")
            continue
        username = name.replace(" ", "_")

    my_id = gen_id(username)

    print()
    print("  Generating ID...")
    time.sleep(0.5)

    cfg = {
        "username": username,
        "my_id": my_id,
        "friends": {},
        "pending_outgoing": {},
        "pending_incoming": {},
        "offline_queue": [],
        "last_seen": {},
        "created": now_full(),
        "version": VERSION,
    }

    if not save_config(cfg):
        print("  [ERROR] Cannot save.")
        return None

    clear()
    print("=" * 55)
    print("  YOUR PERMANENT ID")
    print("=" * 55)
    print()
    print()
    print("      " + my_id)
    print()
    print()
    print("=" * 55)
    print()
    print("  ⚠️  SAVE THIS ID!")
    print()
    print("  Share with friends. They use:")
    print("    /add YOUR_NAME " + my_id)
    print()
    print("=" * 55)
    print()
    input("  Press ENTER...")
    return cfg

def groups_menu(client):
    while True:
        clear()
        print("=" * 55)
        print("  GROUPS (" + str(len(client.groups)) + ")")
        print("=" * 55)
        print()
        if client.group_invites:
            print("  🔔 " + str(len(client.group_invites)) + " pending invite(s)")
            print()
        for i, (gname, ginfo) in enumerate(client.groups.items(), 1):
            unread = client.unread.get("G:" + gname, 0)
            unread_str = " (" + str(unread) + " new)" if unread else ""
            print("  " + str(i) + ". " + gname + unread_str)
            print("     members: " + str(len(ginfo.get("members", {}))))
            print()
        if not client.groups:
            print("  No groups yet.")
            print()
        print("  [C] Create new group")
        print("  [I] Show invites (" + str(len(client.group_invites)) + ")")
        print("  [V] Invite friend to group")
        print("  [O] Open group")
        print("  [L] Leave group")
        print("  [K] Kick member (owner)")
        print("  [R] Rename group (owner)")
        print("  [D] Delete group (owner)")
        print("  [F] Show group info")
        print("  [0] Back")
        print()
        try:
            c = input("Select: ").strip()
        except (EOFError, KeyboardInterrupt):
            return
        if c == "0":
            return
        elif c.upper() == "C":
            name = input("  Group name: ").strip().lower()
            if name:
                gid, err = client.group_create(name)
                if gid:
                    print("[OK] Created: " + name)
                else:
                    print("[!] " + err)
                input("  ENTER...")
        elif c.upper() == "I":
            show_group_invites(client)
        elif c.upper() == "V":
            gname = input("  Group name: ").strip().lower()
            if not gname:
                continue
            fname = input("  Friend name: ").strip().lower()
            if not fname:
                continue
            fid = input("  Friend ID: ").strip().upper()
            if not fid:
                continue
            ok, err = client.group_invite(gname, fname, fid)
            if ok:
                print("[OK] Invited: " + fname)
            else:
                print("[!] " + err)
            input("  ENTER...")
        elif c.upper() == "O":
            name = input("  Group name: ").strip().lower()
            if name:
                result = group_chat_mode(client, name)
                if result == "quit":
                    return
        elif c.upper() == "L":
            name = input("  Group name: ").strip().lower()
            if name:
                ok, err = client.group_leave(name)
                if ok:
                    print("[OK] Left: " + name)
                else:
                    print("[!] " + err)
                input("  ENTER...")
        elif c.upper() == "K":
            gname = input("  Group name: ").strip().lower()
            if not gname:
                continue
            mname = input("  Member name: ").strip().lower()
            if not mname:
                continue
            ok, err = client.group_kick(gname, mname)
            if ok:
                print("[OK] Kicked: " + mname)
            else:
                print("[!] " + err)
            input("  ENTER...")
        elif c.upper() == "R":
            oname = input("  Old name: ").strip().lower()
            if not oname:
                continue
            nname = input("  New name: ").strip().lower()
            if not nname:
                continue
            ok, err = client.group_rename(oname, nname)
            if ok:
                print("[OK] Renamed: " + oname + " -> " + nname)
            else:
                print("[!] " + err)
            input("  ENTER...")
        elif c.upper() == "D":
            gname = input("  Group name: ").strip().lower()
            if not gname:
                continue
            print("  Delete group '" + gname + "'? (y/N): ")
            ans = input("  > ").strip().lower()
            if ans != "y":
                print("[Cancelled]")
                input("  ENTER...")
                continue
            ok, err = client.group_delete(gname)
            if ok:
                print("[OK] Deleted: " + gname)
            else:
                print("[!] " + err)
            input("  ENTER...")
        elif c.upper() == "F":
            gname = input("  Group name: ").strip().lower()
            if gname:
                show_group_info(client, gname)


def show_group_invites(client):
    clear()
    print("=" * 55)
    print("  GROUP INVITES (" + str(len(client.group_invites)) + ")")
    print("=" * 55)
    print()
    if not client.group_invites:
        print("  No invites.")
        print()
        input("  ENTER...")
        return
    for i, (gname, info) in enumerate(client.group_invites.items(), 1):
        print("  " + str(i) + ". " + gname)
        print("     From: " + info.get("owner_name", "?"))
        print("     At:   " + info.get("invited_at", "?"))
        print()
    print("  Commands:")
    print("    /accept_group NAME")
    print("    /reject_group NAME")
    print()
    input("  ENTER...")


def show_group_info(client, group_name):
    gname = group_name.strip().lower()
    if gname not in client.groups:
        print()
        print("[!] No such group: " + gname)
        input("  ENTER...")
        return
    ginfo = client.groups[gname]
    clear()
    print("=" * 55)
    print("  GROUP INFO: " + gname)
    print("=" * 55)
    print()
    print("  ID:      " + ginfo.get("id", "?"))
    print("  Name:    " + ginfo.get("name", "?"))
    owner_id = ginfo.get("owner", "")
    if owner_id == client.my_id:
        print("  Owner:   You (" + owner_id + ")")
    else:
        owner_name = ginfo.get("members", {}).get(owner_id, "?")
        print("  Owner:   " + owner_name + " (" + owner_id + ")")
    print("  Created: " + ginfo.get("created", "?"))
    print()
    print("  Members (" + str(len(ginfo.get("members", {}))) + "):")
    for mid, mname in ginfo.get("members", {}).items():
        marker = "*" if mid == client.my_id else "-"
        suffix = " (owner)" if mid == owner_id else ""
        print("    " + marker + " " + mname + suffix)
    print()
    print("=" * 55)
    input("  ENTER...")


def group_chat_mode(client, group_name):
    gname = group_name.strip().lower()
    if gname not in client.groups:
        print()
        print("[!] No such group: " + gname)
        input("  ENTER...")
        return None
    ginfo = client.groups[gname]

    client.unread["G:" + gname] = 0

    clear()
    print("=" * 55)
    print("  GROUP: " + gname)
    print("=" * 55)
    print()
    members = ginfo.get("members", {})
    print("  Members: " + str(len(members)))
    for mid, mname in members.items():
        if mid == client.my_id:
            print("    * " + mname + " (you)")
        else:
            print("    - " + mname)
    print()
    print("  /back to return, /quit to exit")
    print("=" * 55)
    print()

    with client.lock:
        client.current_chat = "G:" + gname

    try:
        while True:
            try:
                msg = input("> ")
            except (EOFError, KeyboardInterrupt):
                break
            stripped = msg.strip()
            if not stripped:
                continue
            if stripped.startswith("/"):
                parts = stripped.split(" ", 1)
                cmd = parts[0].lower()
                if cmd in ("/back", "/exit"):
                    break
                elif cmd == "/quit":
                    with client.lock:
                        client.current_chat = None
                    return "quit"
                elif cmd == "/help":
                    print_help()
                    continue
                elif cmd == "/members":
                    print()
                    for mid, mname in members.items():
                        print("  " + mname + " (" + mid + ")")
                    print()
                    continue
                else:
                    print("[!] Unknown. /help")
                    continue

            processed = apply_emoji(stripped)
            ok, err = client.group_send(gname, processed)
            ts = now_short()
            if ok:
                print("[" + ts + "] You: " + processed)
                client._log("group_" + gname, "You", processed, ts)
            else:
                print("[!] Send failed: " + err)

    finally:
        with client.lock:
            client.current_chat = None

    return None



# ============================================================
# MAIN LOOP
# ============================================================

def main_loop(client):
    while True:
        clear()
        print("=" * 55)
        print("  TERMUX AI - P2P CHAT v" + VERSION)
        print("=" * 55)
        print()
        print("  User: " + client.username)
        print("  ID:   " + client.my_id)
        print("  Status: " + ("● Online" if client.connected else "○ Offline"))
        print()

        total_unread = sum(client.unread.values())
        if total_unread:
            print("  📩 " + str(total_unread) + " unread message(s)")
        if client.pending_in:
            print("  🔔 " + str(len(client.pending_in)) +
                  " pending request(s) -> /requests")
        if client.offline_queue:
            print("  📤 " + str(len(client.offline_queue)) + " queued -> /queue")
        if client.pending_files:
            print("  📎 " + str(len(client.pending_files)) + " pending file(s) -> Y/N")
        if total_unread or client.pending_in or client.offline_queue or client.pending_files:
            print()

        print("  [1] Chat with friend")
        print("  [2] Friends list")
        print("  [3] Show my ID")
        print("  [4] Add friend")
        print("  [5] Requests (" + str(len(client.pending_in)) + ")")
        print("  [6] Help")
        print("  [7] Groups")
        print("  [0] Exit")
        print()

        try:
            c = input("Select: ").strip()
        except (EOFError, KeyboardInterrupt):
            return

        if c == "0":
            return
        elif c == "1":
            if not client.friends:
                print("[!] No friends.")
                input("  ENTER...")
                continue
            name = input("  Friend name: ").strip().lower()
            if name:
                result = chat_mode(client, name)
                if result == "quit":
                    return
        elif c == "2":
            show_friends(client)
        elif c == "3":
            show_me(client)
        elif c == "4":
            parts = input("  /add: ").strip().split()
            if not parts:
                continue
            if parts[0] != "/add":
                parts = ["/add"] + parts
            action_add(client, parts)
            input("  ENTER...")
        elif c == "5":
            if client.pending_in:
                show_requests(client)
            else:
                print("[!] No pending requests.")
                input("  ENTER...")
        elif c == "6":
            print_help()
            input("  ENTER...")
        elif c == "7":
            groups_menu(client)
        elif c in ("Y", "y") and client.pending_files:
            _do_accept_file(client)
        elif c in ("N", "n") and client.pending_files:
            _do_reject_file(client)
        elif c in ("Y", "y") and client.pending_approvals:
            _do_approve(client)
        elif c in ("N", "n") and client.pending_approvals:
            _do_reject(client)
        elif c.startswith("/"):
            parts = c.split(" ", 1)
            cmd = parts[0].lower()
            if cmd == "/me":
                show_me(client)
            elif cmd == "/friends":
                show_friends(client)
            elif cmd == "/requests":
                show_requests(client)
            elif cmd == "/group":
                if len(parts) > 1:
                    sub = parts[1].split()
                    if sub:
                        subcmd = sub[0].lower()
                        if subcmd == "create" and len(sub) > 1:
                            gid, err = client.group_create(sub[1])
                            if gid:
                                print("[OK] Created: " + sub[1])
                            else:
                                print("[!] " + err)
                        elif subcmd == "invite" and len(sub) > 2:
                            ok, err = client.group_invite(sub[1], sub[2])
                            if ok:
                                print("[OK] Invited: " + sub[2])
                            else:
                                print("[!] " + err)
                        elif subcmd == "list":
                            groups_menu(client)
                        elif subcmd == "kick" and len(sub) > 2:
                            ok, err = client.group_kick(sub[1], sub[2])
                            if ok:
                               print("[OK] Kicked: " + sub[2])
                            else:
                               print("[!] " + err)
                        elif subcmd == "rename" and len(sub) > 2:
                            ok, err = client.group_rename(sub[1], sub[2])
                            if ok:
                               print("[OK] Renamed: " + sub[1] + " -> " + sub[2])
                            else:
                               print("[!] " + err)
                        elif subcmd == "delete" and len(sub) > 1:
                            ok, err = client.group_delete(sub[1])
                            if ok:
                               print("[OK] Deleted: " + sub[1])
                            else:
                               print("[!] " + err)
                        elif subcmd == "info" and len(sub) > 1:
                            show_group_info(client, sub[1])
                        else:
                            print("[!] Usage: /group create NAME")
                            print("      /group invite GROUP FRIEND")
                            print("      /group list")
                else:
                    groups_menu(client)
                input("  ENTER...")
            elif cmd == "/accept_group":
                if len(parts) > 1:
                    ok, err = client.group_accept(parts[1])
                    if ok:
                        print("[OK] Joined: " + parts[1])
                    else:
                        print("[!] " + err)
                input("  ENTER...")
            elif cmd == "/reject_group":
                if len(parts) > 1:
                    ok, err = client.group_reject(parts[1])
                    if ok:
                        print("[OK] Rejected: " + parts[1])
                    else:
                        print("[!] " + err)
                input("  ENTER...")
            elif cmd == "/g":
                if len(parts) > 1:
                    result = group_chat_mode(client, parts[1])
                    if result == "quit":
                        return
            elif cmd == "/queue":
                show_queue(client)
            elif cmd == "/add":
                action_add(client, c.split())
                input("  ENTER...")
            elif cmd == "/accept":
                action_accept(client, c.split())
                input("  ENTER...")
            elif cmd == "/file":
                if len(parts) > 1:
                    args = parts[1].split(" ", 2)
                    if len(args) < 2:
                        print("[!] Usage: /file FRIEND PATH [SAVE_DIR]")
                        input("  ENTER...")
                        continue
                    fname = args[0].strip().lower()
                    fpath = args[1].strip()
                    spath = args[2].strip() if len(args) > 2 else None
                    ok, err = send_file(client, fname, fpath, spath)
                    if ok:
                        print("[OK] File sent.")
                    else:
                        print("[!] " + err)
                else:
                    print("[!] Usage: /file FRIEND PATH [SAVE_DIR]")
                input("  ENTER...")

            elif cmd == "/fileg":
                if len(parts) > 1:
                    args = parts[1].split(" ", 2)
                    if len(args) < 2:
                        print("[!] Usage: /fileg GROUP PATH [SAVE_DIR]")
                        input("  ENTER...")
                        continue
                    gname = args[0].strip().lower()
                    fpath = args[1].strip()
                    spath = args[2].strip() if len(args) > 2 else None
                    ok, err = send_file_group(client, gname, fpath, spath)
                    if ok:
                        print("[OK] File sent to group.")
                    else:
                        print("[!] " + err)
                else:
                    print("[!] Usage: /fileg GROUP PATH [SAVE_DIR]")
                input("  ENTER...")

            elif cmd == "/cmd":
                if len(parts) > 1:
                    args = parts[1].split(" ", 1)

                    if len(args) < 2:
                        print("[!] Usage: /cmd FRIEND COMMAND")
                        input("  ENTER...")
                        continue
                    fname = args[0].strip().lower()
                    cmd_text = args[1].strip()
                    ok, err, req_id = client.send_cmd(fname, cmd_text)
                    if ok:
                        print("[OK] Sent. Waiting for result...")
                        print("     Req ID: " + req_id)
                    else:
                        print("[!] " + err)
                else:
                    print("[!] Usage: /cmd FRIEND COMMAND")
                input("  ENTER...")

            elif cmd == "/approve":
                if not client.pending_approvals:
                    print("[!] No pending approvals.")
                    input("  ENTER...")
                    continue
                if len(parts) > 1:
                    rid = parts[1].strip().upper()
                else:
                    rid = list(client.pending_approvals.keys())[-1]
                if rid not in client.pending_approvals:
                    print("[!] Unknown request.")
                    input("  ENTER...")
                    continue
                info = client.pending_approvals[rid]
                print("\nRunning: " + info["cmd"])
                print("Please wait...")
                ok, output = client.approve_cmd(rid)
                if ok:
                    print("[OK] Executed and result sent.")
                else:
                    print("[!] " + output)
                input("  ENTER...")

            elif cmd == "/reject_cmd":
                if not client.pending_approvals:
                    print("[!] No pending approvals.")
                    input("  ENTER...")
                    continue
                if len(parts) > 1:
                    rid = parts[1].strip().upper()
                else:
                    rid = list(client.pending_approvals.keys())[-1]
                if client.reject_cmd(rid):
                    print("[OK] Rejected.")
                else:
                    print("[!] Not found.")
                input("  ENTER...")

            elif cmd == "/reject":
                action_reject(client, c.split())
                input("  ENTER...")
            elif cmd == "/remove":
                action_remove(client, c.split())
                input("  ENTER...")
            elif cmd == "/chat":
                if len(parts) > 1:
                    result = chat_mode(client, parts[1])
                    if result == "quit":
                        return
            elif cmd == "/help":
                print_help()
                input("  ENTER...")
            elif cmd == "/quit":
                return
            else:
                print("[!] Unknown.")
                input("  ENTER...")
        else:
            print("[!] Invalid.")
            time.sleep(0.5)

def _do_approve(client):
    rid = list(client.pending_approvals.keys())[-1]
    info = client.pending_approvals[rid]
    print()
    print("Running: " + info["cmd"])
    print("Please wait...")
    ok, output = client.approve_cmd(rid)
    if ok:
        print("[OK] Executed and result sent.")
    else:
        print("[!] " + output)
    input("  ENTER...")


def _do_reject(client):
    rid = list(client.pending_approvals.keys())[-1]
    if client.reject_cmd(rid):
        print("[OK] Rejected.")
    else:
        print("[!] Not found.")
    input("  ENTER...")


def _do_accept_file(client):
    if not client.pending_files:
        print("[!] No pending files.")
        input("  ENTER...")
        return
    item = client.pending_files.pop(0)
    filename = item["filename"]
    save_dir = item["save_dir"]
    file_bytes = item["file_bytes"]
    size = item["size"]
    from_name = item["from_name"]
    target = os.path.join(save_dir, filename)
    base, ext = os.path.splitext(filename)
    i = 1
    while os.path.exists(target):
        target = os.path.join(save_dir, base + "_" + str(i) + ext)
        i += 1
    try:
        with open(target, "wb") as f:
            f.write(file_bytes)
    except Exception as e:
        print("[!] Save failed: " + str(e))
        input("  ENTER...")
        return
    print()
    print("[OK] File accepted and saved.")
    print("     From: " + from_name)
    print("     Size: " + str(size) + " bytes")
    print("     Path: " + target)
    input("  ENTER...")


def _do_reject_file(client):
    if not client.pending_files:
        print("[!] No pending files.")
        input("  ENTER...")
        return
    item = client.pending_files.pop(0)
    filename = item["filename"]
    from_name = item["from_name"]
    print()
    print("[OK] File rejected.")
    print("     From: " + from_name)
    print("     Name: " + filename)
    input("  ENTER...")



# ============================================================
# MAIN
# ============================================================

def main():
    cfg = load_config()

    if not cfg.get("username") or not cfg.get("my_id"):
        cfg = first_run()
        if not cfg:
            print("\nSetup cancelled.")
            return

    client = P2PClient(cfg)

    clear()
    print("=" * 55)
    print("  TERMUX AI - P2P CHAT v" + VERSION)
    print("=" * 55)
    print()
    print("  User: " + client.username)
    print("  ID:   " + client.my_id)
    print()

    if not client.mqtt_connect():
        print()
        print("  ⚠️  Not connected yet.")
        print("     Will retry automatically when online.")
        print("     Messages will be queued.")
        print()
        time.sleep(1)
    else:
        print()
        print("  ✓ Connected to broker.")
        print()
        time.sleep(0.5)

    try:
        main_loop(client)
    except KeyboardInterrupt:
        pass
    finally:
        client.save()
        client.mqtt_disconnect()

    print()
    print("Goodbye!")


if __name__ == "__main__":
    main()
P2P_CHAT_PY_EOF
        chmod 700 "$P2P_CHAT_TARGET"
        print_ok "Created p2p_chat.py"
    fi

    # ============================================================
    # WEB ENGINE - TEXT-BASED BROWSER
    # ============================================================
    WEB_ENGINE_TARGET="web_engine.py"

    if [ ! -f "$WEB_ENGINE_TARGET" ]; then
        cat > "$WEB_ENGINE_TARGET" << 'WEB_ENGINE_PY_EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Termux AI Web Engine v2.0
Text-based web browser for Termux
Supports multiple search engines
"""

import sys
import re
import os
import json
import urllib.request
import http.cookiejar
import urllib.error
import urllib.parse
import ssl
import socket
from html.parser import HTMLParser
from html import unescape

VERSION = "2.0"
DEFAULT_SCHEME = "https"
USER_AGENT = "TermuxAI/2.0 (Text Browser)"
TIMEOUT = 15
MAX_LINKS = 60
MAX_TEXT_CHARS = 6000

# ============================================================
# SEARCH ENGINES CONFIGURATION
# ============================================================
SEARCH_ENGINES = [
{
    "name": "Bing",
    "url": "https://www.bing.com/search?q=",
    "desc": "يعمل بالعربية، نتائج قوية",
},
{
    "name": "Wikipedia",
    "url": "https://en.wikipedia.org/w/index.php?search=",
    "desc": "الموسوعة الحرة",
},
{
    "name": "Wiby",
    "url": "https://wiby.org/?q=",
    "desc": "مواقع قديمة نصية",
},
{
    "name": "DuckDuckGo Lite",
    "url": "https://lite.duckduckgo.com/lite/?q=",
    "desc": "نتائج حقيقية، سريع",
},
]

DEFAULT_SEARCH_INDEX = 0  # Bing (الأفضل في مصر)

# ============================================================
# CUSTOM ENGINES - User-added engines
# ============================================================

CUSTOM_ENGINES_FILE = os.path.expanduser("~/.termux_ai_custom_engines.txt")


def _load_custom_engines():
    """Load custom engines from file at startup"""
    if not os.path.exists(CUSTOM_ENGINES_FILE):
        return
    try:
        with open(CUSTOM_ENGINES_FILE, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "|" not in line:
                    continue
                name, url = line.split("|", 1)
                name = name.strip()
                url = url.strip()
                if name and url:
                    SEARCH_ENGINES.append({
                        "name": name + " ★",
                        "url": url,
                        "desc": "Custom engine",
                    })
    except Exception:
        pass


_load_custom_engines()


def save_custom_engine(name, url):
    """Save custom engine to file"""
    try:
        with open(CUSTOM_ENGINES_FILE, "a", encoding="utf-8") as f:
            f.write(name + "|" + url + "\n")
        return True
    except Exception:
        return False


def add_custom_engine(state):
    """Prompt user for name and URL, then add to list"""
    clear()
    print("=" * 55)
    print("     ADD CUSTOM SEARCH ENGINE")
    print("=" * 55)
    print()

    try:
        name = input("Engine name: ").strip()
    except (EOFError, KeyboardInterrupt):
        return

    if not name:
        print("\n[ERROR] Name is empty.")
        pause()
        return

    print()
    print("Enter search URL.")
    print("Must end with  =  or  ?q=  etc.")
    print("Example: https://example.com/search?q=")
    print()

    try:
        url = input("URL: ").strip()
    except (EOFError, KeyboardInterrupt):
        return

    if not url:
        print("\n[ERROR] URL is empty.")
        pause()
        return

    if not url.startswith("http://") and not url.startswith("https://"):
        url = "https://" + url

    if save_custom_engine(name, url):
        SEARCH_ENGINES.append({
            "name": name + " ★",
            "url": url,
            "desc": "Custom engine",
        })
        idx = len(SEARCH_ENGINES) - 1
        print()
        print("[OK] Saved.")
        print("     Press " + str(idx + 1) + " to select")
    else:
        print()
        print("[ERROR] Save failed.")

    pause()

# ============================================================
# HTML PARSER
# ============================================================

class PageParser(HTMLParser):
    def __init__(self):
        try:
            super().__init__(convert_charrefs=True)
        except TypeError:
            super().__init__()
        self.title = ""
        self.text_parts = []
        self.links = []
        self.buttons = []
        self.forms = []
        self._in_title = False
        self._in_script = False
        self._in_style = False
        self._current_link = None
        self._current_link_text = []
        self._current_button_text = None
        self.next_url = None
        self.prev_url = None

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        ad = {}
        for k, v in attrs:
            ad[k.lower()] = v

        if tag == "title":
            self._in_title = True
        elif tag == "script":
            self._in_script = True
        elif tag == "style":
            self._in_style = True
        elif tag == "a":
            href = (ad.get("href") or "").strip()
            rel = (ad.get("rel") or "").lower()
            cls = (ad.get("class") or "").lower()
            if href and not href.startswith(("#", "javascript:", "mailto:", "tel:")):
                self._current_link = {
                    "url": href,
                    "title": (ad.get("title") or "").strip(),
                    "rel": rel,
                    "class": cls,
                }
                self._current_link_text = []
        elif tag == "button":
            self._current_button_text = []
        elif tag == "form":
            self.forms.append({
                "action": (ad.get("action") or "").strip(),
                "method": (ad.get("method") or "get").upper(),
            })
        elif tag in ("p", "br", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "tr"):
            self.text_parts.append("\n")

    def handle_endtag(self, tag):
        tag = tag.lower()
        if tag == "title":
            self._in_title = False
        elif tag == "script":
            self._in_script = False
        elif tag == "style":
            self._in_style = False
        elif tag == "a" and self._current_link:
            text = "".join(self._current_link_text).strip()
            text = re.sub(r"\s+", " ", text)
            if text:
                self._current_link["text"] = text
                self.links.append(self._current_link)

            low_text = text.lower()
            low_rel = self._current_link.get("rel", "")
            low_cls = self._current_link.get("class", "")

            is_next = False
            if "next" in low_rel:
                is_next = True
            elif low_text in ("next", "next >", "next page", "next →", "next ›", "next »", "التالي", "الصفحة التالية", "التالي ›"):
                is_next = True
            elif "next" in low_text and len(low_text) < 20:
                is_next = True
            elif "next" in low_cls:
                is_next = True

            if is_next and not self.next_url:
                self.next_url = self._current_link["url"]

            is_prev = False
            if "prev" in low_rel or "previous" in low_rel:
                is_prev = True
            elif low_text in ("prev", "< prev", "previous", "← prev", "‹ prev", "« prev", "السابق", "الصفحة السابقة", "‹ السابق"):
                is_prev = True
            elif "prev" in low_text and len(low_text) < 20:
                is_prev = True
            elif "prev" in low_cls:
                is_prev = True

            if is_prev and not self.prev_url:
                self.prev_url = self._current_link["url"]

            self._current_link = None
            self._current_link_text = []
        elif tag == "button" and self._current_button_text is not None:
            text = "".join(self._current_button_text).strip()
            text = re.sub(r"\s+", " ", text)
            if text:
                self.buttons.append(text)
            self._current_button_text = None

    def handle_data(self, data):
        if self._in_script or self._in_style:
            return
        if self._in_title:
            self.title += data
        elif self._current_link is not None:
            self._current_link_text.append(data)
        elif self._current_button_text is not None:
            self._current_button_text.append(data)
        else:
            self.text_parts.append(data)

    def get_text(self):
        text = "".join(self.text_parts)
        try:
            text = unescape(text)
        except Exception:
            pass
        text = re.sub(r"[ \t]+", " ", text)
        text = re.sub(r"\n\s*\n+", "\n\n", text)
        return text.strip()


# ============================================================
# URL UTILITIES
# ============================================================

def normalize_url(url):
    url = url.strip()
    if not url:
        return ""
    if not re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*://", url):
        url = DEFAULT_SCHEME + "://" + url
    return url


def is_valid_url(url):
    if not url:
        return False
    try:
        p = urllib.parse.urlparse(url)
        if p.scheme not in ("http", "https"):
            return False
        if not p.netloc:
            return False
        return True
    except Exception:
        return False


def resolve_url(base, relative):
    try:
        return urllib.parse.urljoin(base, relative)
    except Exception:
        return relative

def github_redirect(url):
    """Detect GitHub releases URL and redirect to expanded_assets"""
    if "github.com" not in url:
        return None

    # Pattern 1: /releases/tag/TAG
    m = re.match(r'^https?://github\.com/([^/]+)/([^/]+)/releases/tag/([^/?#]+)', url)
    if m:
        owner, repo, tag = m.group(1), m.group(2), m.group(3)
        return "https://github.com/" + owner + "/" + repo + "/releases/expanded_assets/" + tag

    # Pattern 2: /releases (main page) -> get latest release via API
    m = re.match(r'^https?://github\.com/([^/]+)/([^/]+)/releases/?$', url)
    if m:
        owner, repo = m.group(1), m.group(2)
        try:
            api_url = "https://api.github.com/repos/" + owner + "/" + repo + "/releases/latest"
            req = urllib.request.Request(api_url)
            req.add_header("User-Agent", USER_AGENT)
            req.add_header("Accept", "application/vnd.github+json")
            with _opener.open(req, timeout=10) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                tag = data.get("tag_name", "")
                if tag:
                    return "https://github.com/" + owner + "/" + repo + "/releases/expanded_assets/" + tag
        except Exception:
            pass

    return None


# ============================================================
# NETWORK
# ============================================================
# Global cookie jar for session persistence
_cookie_jar = http.cookiejar.CookieJar()
_cookie_processor = urllib.request.HTTPCookieProcessor(_cookie_jar)
_opener = urllib.request.build_opener(_cookie_processor)


def fetch_page(url):
    if not is_valid_url(url):
        return False, "", url, "Invalid URL"

    try:
        ctx = ssl.create_default_context()
    except Exception:
        ctx = ssl._create_unverified_context()

    req = urllib.request.Request(url)
    req.add_header("User-Agent", USER_AGENT)
    req.add_header("Accept", "text/html,application/xhtml+xml,*/*;q=0.8")
    req.add_header("Accept-Language", "ar,en;q=0.9")

    try:
        with _opener.open(req, timeout=TIMEOUT) as resp:
            final_url = resp.geturl()
            ctype = resp.headers.get("Content-Type", "")

            if ctype and "html" not in ctype.lower() and "text" not in ctype.lower():
                return False, "", final_url, "Not HTML: " + ctype

            raw = resp.read()

            charset = "utf-8"
            m = re.search(r"charset=([\w-]+)", ctype, re.I)
            if m:
                charset = m.group(1)

            try:
                text = raw.decode(charset, errors="replace")
            except (LookupError, UnicodeDecodeError):
                text = raw.decode("utf-8", errors="replace")

            return True, text, final_url, ""

    except urllib.error.HTTPError as e:
        return False, "", url, "HTTP " + str(e.code) + " " + str(e.reason)
    except urllib.error.URLError as e:
        return False, "", url, "Network: " + str(e.reason)
    except socket.timeout:
        return False, "", url, "Timeout"
    except ssl.SSLError as e:
        return False, "", url, "SSL: " + str(e)


# ============================================================
# DOWNLOAD
# ============================================================

DOWNLOAD_EXTS = {
    ".apk", ".zip", ".tar", ".gz", ".tgz", ".bz2", ".xz", ".7z", ".rar",
    ".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx",
    ".mp3", ".mp4", ".avi", ".mkv", ".mov", ".wav", ".flac", ".webm",
    ".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp", ".svg", ".ico",
    ".deb", ".rpm", ".exe", ".msi", ".dmg", ".iso", ".img",
    ".txt", ".csv", ".json", ".xml", ".log",
    ".py", ".sh", ".js", ".css",
    ".torrent",
    ".epub", ".mobi", ".azw", ".azw3",
    ".ttf", ".otf", ".woff", ".woff2",
}


def get_download_dir():
    shared = os.path.expanduser("~/storage/shared/Download")
    if os.path.isdir(shared):
        return shared
    local = os.path.expanduser("~/downloads")
    try:
        os.makedirs(local, exist_ok=True)
    except Exception:
        pass
    return local


def url_looks_like_file(url):
    try:
        path = urllib.parse.urlparse(url).path.lower()
        for ext in DOWNLOAD_EXTS:
            if path.endswith(ext):
                return True
    except Exception:
        pass
    return False

def filename_from_url(url):
    try:
        parsed = urllib.parse.urlparse(url)
        path = parsed.path
        name = os.path.basename(path)

        # Clean weird chars
        name = re.sub(r'[^\w\.\-_ ]', '_', name)

        # If empty or too generic → use hostname
        if not name or name.lower() in ("download", "file", "index", "index.html", "get", "dl"):
            host = parsed.netloc.split(":")[0].replace(".", "_")
            import time
            name = host + "_" + str(int(time.time()))

        # Limit length
        if len(name) > 100:
            base, ext = os.path.splitext(name)
            name = base[:90] + ext

        return name
    except Exception:
        import time
        return "download_" + str(int(time.time()))


def extension_from_content_type(ctype):
    if not ctype:
        return ""
    ctype = ctype.lower().split(";")[0].strip()

    mapping = {
        "application/vnd.android.package-archive": ".apk",
        "application/pdf": ".pdf",
        "application/zip": ".zip",
        "application/x-zip-compressed": ".zip",
        "application/x-rar-compressed": ".rar",
        "application/vnd.rar": ".rar",
        "application/x-tar": ".tar",
        "application/gzip": ".gz",
        "application/x-7z-compressed": ".7z",
        "application/json": ".json",
        "application/xml": ".xml",
        "application/javascript": ".js",
        "application/x-javascript": ".js",
        "application/msword": ".doc",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document": ".docx",
        "application/vnd.ms-excel": ".xls",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": ".xlsx",
        "application/octet-stream": ".bin",
        "text/plain": ".txt",
        "text/html": ".html",
        "text/css": ".css",
        "text/csv": ".csv",
        "image/jpeg": ".jpg",
        "image/png": ".png",
        "image/gif": ".gif",
        "image/webp": ".webp",
        "image/svg+xml": ".svg",
        "image/x-icon": ".ico",
        "video/mp4": ".mp4",
        "video/webm": ".webm",
        "video/x-matroska": ".mkv",
        "audio/mpeg": ".mp3",
        "audio/wav": ".wav",
        "audio/ogg": ".ogg",
        "audio/flac": ".flac",
    }

    return mapping.get(ctype, "")


def filename_from_headers(headers):
    cd = headers.get("Content-Disposition", "")
    if not cd:
        return None

    # RFC 5987: filename*=UTF-8''name.ext
    m = re.search(r"filename\*=UTF-8''([^;]+)", cd, re.I)
    if m:
        try:
            name = urllib.parse.unquote(m.group(1)).strip()
            name = re.sub(r'[^\w\.\-_ ]', '_', name)
            return name
        except Exception:
            pass

    # RFC 5987 lowercase
    m = re.search(r"filename\*=utf-8''([^;]+)", cd, re.I)
    if m:
        try:
            name = urllib.parse.unquote(m.group(1)).strip()
            name = re.sub(r'[^\w\.\-_ ]', '_', name)
            return name
        except Exception:
            pass

    # Standard: filename="name.ext"
    m = re.search(r'filename="([^"]+)"', cd, re.I)
    if m:
        name = m.group(1).strip()
        name = re.sub(r'[^\w\.\-_ ]', '_', name)
        return name

    # Without quotes: filename=name.ext
    m = re.search(r'filename=([^\s;]+)', cd, re.I)
    if m:
        name = m.group(1).strip().strip('"').strip("'")
        name = re.sub(r'[^\w\.\-_ ]', '_', name)
        return name

    return None


def format_size(n):
    if n < 1024:
        return str(n) + " B"
    elif n < 1024 * 1024:
        return "%.1f KB" % (n / 1024)
    elif n < 1024 * 1024 * 1024:
        return "%.1f MB" % (n / 1024 / 1024)
    else:
        return "%.2f GB" % (n / 1024 / 1024 / 1024)


def download_file(url, save_dir=None):
    url = normalize_url(url)
    if not is_valid_url(url):
        print("[ERROR] Invalid URL")
        return False

    if save_dir is None:
        save_dir = get_download_dir()

    print()
    print("=" * 55)
    print("  DOWNLOAD")
    print("=" * 55)
    print()
    print("URL: " + url)
    print()

    try:
        req = urllib.request.Request(url)
        req.add_header("User-Agent", USER_AGENT)
        req.add_header("Accept", "*/*")

        with _opener.open(req, timeout=60) as resp:
            name = filename_from_headers(resp.headers)
            if not name:
                name = filename_from_url(url)

            # If no extension → try from content-type
            if not os.path.splitext(name)[1]:
                ctype_for_ext = resp.headers.get("Content-Type", "")
                ext = extension_from_content_type(ctype_for_ext)
                if ext:
                    name = name + ext
                else:
                    name = name + ".bin"

            size_str = resp.headers.get("Content-Length", "")
            try:
                total_size = int(size_str)
            except (ValueError, TypeError):
                total_size = 0

            ctype = resp.headers.get("Content-Type", "")

            print("Filename: " + name)
            print("Type:     " + (ctype or "unknown"))
            if total_size > 0:
                print("Size:     " + format_size(total_size))
            else:
                print("Size:     (unknown)")
            print()

            if "html" in ctype.lower() and not url_looks_like_file(url):
                print("[!] This appears to be an HTML page, not a file.")
                print("    Continue anyway? (y/N)")
                try:
                    ans = input("> ").strip().lower()
                except (EOFError, KeyboardInterrupt):
                    return False
                if ans != "y":
                    print("Download cancelled.")
                    return False
                print()

            target = os.path.join(save_dir, name)
            base, ext = os.path.splitext(name)
            i = 1
            while os.path.exists(target):
                target = os.path.join(save_dir, base + "_" + str(i) + ext)
                i += 1

            print("Saving to: " + target)
            print()

            downloaded = 0
            chunk_size = 8192
            last_percent = -1

            with open(target, "wb") as f:
                while True:
                    chunk = resp.read(chunk_size)
                    if not chunk:
                        break
                    f.write(chunk)
                    downloaded += len(chunk)

                    if total_size > 0:
                        percent = int(downloaded * 100 / total_size)
                        if percent != last_percent and percent % 5 == 0:
                            bar_len = 30
                            filled = int(bar_len * percent / 100)
                            bar = "=" * filled + "-" * (bar_len - filled)
                            sys.stdout.write("\r  [" + bar + "] " + str(percent) + "%  (" + format_size(downloaded) + "/" + format_size(total_size) + ")")
                            sys.stdout.flush()
                            last_percent = percent
                    else:
                        if downloaded % (1024 * 1024) < chunk_size:
                            sys.stdout.write("\r  Downloaded: " + format_size(downloaded))
                            sys.stdout.flush()

            print()
            print()
            print("[OK] Download complete.")
            print("     " + target)
            return True

    except urllib.error.HTTPError as e:
        print()
        print("[ERROR] HTTP " + str(e.code) + " " + str(e.reason))
        return False
    except urllib.error.URLError as e:
        print()
        print("[ERROR] Network: " + str(e.reason))
        return False
    except socket.timeout:
        print()
        print("[ERROR] Timeout")
        return False
    except KeyboardInterrupt:
        print()
        print("[INFO] Download cancelled.")
        return False
    except Exception as e:
        print()
        print("[ERROR] " + str(e))
        return False


# ============================================================
# BROWSER STATE
# ============================================================

class BrowserState:
    def __init__(self):
        self.url = ""
        self.title = ""
        self.text = ""
        self.links = []
        self.buttons = []
        self.forms = []
        self.history = []
        self.history_index = -1
        self.search_engine = DEFAULT_SEARCH_INDEX
        self.next_url = None
        self.prev_url = None

    def save_to_history(self):
        if self.url:
            self.history = self.history[:self.history_index + 1]
            self.history.append({
                "url": self.url,
                "title": self.title,
                "text": self.text,
                "links": list(self.links),
                "buttons": list(self.buttons),
            })
            self.history_index = len(self.history) - 1

    def restore_from_history(self, index):
        if 0 <= index < len(self.history):
            entry = self.history[index]
            self.url = entry["url"]
            self.title = entry["title"]
            self.text = entry["text"]
            self.links = list(entry["links"])
            self.buttons = list(entry["buttons"])
            self.history_index = index
            return True
        return False


# ============================================================
# DISPLAY HELPERS
# ============================================================

def clear():
    try:
        os.system("clear")
    except Exception:
        print("\n" * 50)


def pause():
    try:
        input("\nPress ENTER to continue...")
    except (EOFError, KeyboardInterrupt):
        pass


# ============================================================
# PAGE LOADING
# ============================================================

def load_page(state, url, verbose=True):
    url = normalize_url(url)
    if not url:
        print("Empty URL.")
        return False

    # GitHub auto-redirect
    gh_url = github_redirect(url)
    if gh_url:
        if verbose:
            print("\n[GitHub] Redirecting to assets page...")
        url = gh_url

    if verbose:
        print("\nFetching: " + url)
        print("Please wait...")

    ok, html, final_url, err = fetch_page(url)

    if not ok:
        print("\n[ERROR] " + err)
        return False

    parser = PageParser()
    try:
        parser.feed(html)
    except Exception as e:
        print("\n[ERROR] Parse failed: " + str(e))
        return False

    state.url = final_url
    state.title = parser.title.strip() or final_url
    state.text = parser.get_text()
    state.buttons = parser.buttons
    state.forms = parser.forms

    state.links = []
    seen = set()
    for lk in parser.links:
        full = resolve_url(final_url, lk["url"])
        if full in seen:
            continue
        seen.add(full)
        state.links.append({"url": full, "text": lk.get("text", "")})
        if len(state.links) >= MAX_LINKS:
            break

    if parser.next_url:
        state.next_url = resolve_url(final_url, parser.next_url)
    else:
        state.next_url = None

    if parser.prev_url:
        state.prev_url = resolve_url(final_url, parser.prev_url)
    else:
        state.prev_url = None

    state.save_to_history()
    return True


# ============================================================
# SEARCH
# ============================================================

def perform_search(state, query):
    engine = SEARCH_ENGINES[state.search_engine]
    q = urllib.parse.quote_plus(query)
    url = engine["url"] + q
    return load_page(state, url)


# ============================================================
# DISPLAY PAGE
# ============================================================

def display_page(state):
    clear()
    print("=" * 55)
    print("  TERMUX AI BROWSER v" + VERSION)
    print("=" * 55)
    print()
    print("Title: " + (state.title or "(no title)"))
    print("URL:   " + (state.url or "(none)"))
    print()
    print("-" * 55)

    if state.links:
        print("\nLinks:\n")
        for i, lk in enumerate(state.links, 1):
            text = lk["text"] or lk["url"]
            if len(text) > 55:
                text = text[:52] + "..."
            marker = ""
            if url_looks_like_file(lk["url"]):
                marker = "[DL] "
            print("[" + str(i) + "] " + marker + text)

    if state.buttons:
        print("\nButtons:\n")
        for i, b in enumerate(state.buttons, 1):
            print("(B" + str(i) + ") " + b[:60])

    if state.text:
        print("\nText:\n")
        text = state.text
        if len(text) > MAX_TEXT_CHARS:
            text = text[:MAX_TEXT_CHARS] + "\n\n...[truncated]"
        print(text)
    else:
        print("\n(No text content extracted)")

    print()
    print("-" * 55)


# ============================================================
# SEARCH ENGINE MENU
# ============================================================

def choose_search_engine(state):
    while True:
        clear()
        print("=" * 55)
        print("  CHOOSE SEARCH ENGINE")
        print("=" * 55)
        print()

        for i, eng in enumerate(SEARCH_ENGINES, 1):
            marker = " *" if i - 1 == state.search_engine else "  "
            print("[" + str(i) + "]" + marker + " " + eng["name"])
            print("      " + eng["desc"])
            print()

        print("[A] Add Custom Engine")
        print("[0] Back")
        print()

        try:
            c = input("Select: ").strip()
        except (EOFError, KeyboardInterrupt):
            return

        if c == "0":
            return

        if c.upper() == "A":
            add_custom_engine(state)
            continue

        try:
            idx = int(c) - 1
        except ValueError:
            print("Invalid number.")
            pause()
            continue

        if 0 <= idx < len(SEARCH_ENGINES):
            state.search_engine = idx
            print("\n✓ Selected: " + SEARCH_ENGINES[idx]["name"])
            pause()
            return
        else:
            print("Out of range.")
            pause()


# ============================================================
# BROWSER LOOP
# ============================================================

def browser_loop(state):
    while True:
        display_page(state)

        engine_name = SEARCH_ENGINES[state.search_engine]["name"]
        print()
        print("Search Engine: " + engine_name)
        print()
        print("[1] Open link by number")
        print("[2] Enter new URL")
        print("[3] Search")
        print("[4] Back")
        print("[5] Reload")
        print("[6] Change Search Engine")
        if state.next_url:print("[7] Next page →")
        if state.prev_url:print("[8] Previous page ←")
        print("[9] Download by number")
        print("[D] Download URL")
        print("[0] Exit")

        try:
            choice = input("\nSelect: ").strip()
        except (EOFError, KeyboardInterrupt):
            return

        if choice == "0":
            return

        elif choice == "1":
            try:
                n = input("Link number: ").strip()
                idx = int(n) - 1
                if 0 <= idx < len(state.links):
                    target = state.links[idx]["url"]
                    if load_page(state, target):
                        continue
                    else:
                        pause()
                else:
                    print("Out of range.")
                    pause()
            except ValueError:
                print("Invalid number.")
                pause()
            except (EOFError, KeyboardInterrupt):
                pass

        elif choice == "2":
            try:
                url = input("URL: ").strip()
            except (EOFError, KeyboardInterrupt):
                continue
            if url:
                if load_page(state, url):
                    continue
                else:
                    pause()

        elif choice == "3":
            try:
                q = input("Search query: ").strip()
            except (EOFError, KeyboardInterrupt):
                continue
            if q:
                if perform_search(state, q):
                    continue
                else:
                    pause()

        elif choice == "4":
            if state.history_index > 0:
                state.restore_from_history(state.history_index - 1)
            else:
                print("No previous page.")
                pause()

        elif choice == "5":
            if state.url:
                if not load_page(state, state.url):
                    pause()
            else:
                print("Nothing to reload.")
                pause()

        elif choice == "6":
            choose_search_engine(state)

        elif choice == "7":
            if state.next_url:
                target = state.next_url
                if load_page(state, target):
                    continue
                else:
                    pause()
            else:
                print("No next page available.")
                pause()

        elif choice == "8":
            if state.prev_url:
                target = state.prev_url
                if load_page(state, target):
                    continue
                else:
                    pause()
            else:
                print("No previous page available.")
                pause()

        elif choice == "9":
            try:
                n = input("Link number to download: ").strip()
                idx = int(n) - 1
                if 0 <= idx < len(state.links):
                    target = state.links[idx]["url"]
                    download_file(target)
                    pause()
                else:
                    print("Out of range.")
                    pause()
            except ValueError:
                print("Invalid number.")
                pause()
            except (EOFError, KeyboardInterrupt):
                pass

        elif choice.upper() == "D":
            try:
                url = input("Download URL: ").strip()
            except (EOFError, KeyboardInterrupt):
                continue
            if url:
                download_file(url)
                pause()

        else:
            print("Invalid choice.")
            pause()

# ============================================================
# BROWSER MENU
# ============================================================

def browser_menu():
    state = BrowserState()
    while True:
        clear()
        print("=" * 55)
        print("  TERMUX AI BROWSER v" + VERSION)
        print("=" * 55)
        print()
        print("Current Search Engine: " + SEARCH_ENGINES[state.search_engine]["name"])
        print()
        print("[1] Enter URL")
        print("[2] Search")
        print("[3] Change Search Engine")
        print("[4] Add Custom Engine")
        print("[0] Exit")
        print()
        try:
            c = input("Select: ").strip()
        except (EOFError, KeyboardInterrupt):
            return

        if c == "0":
            return

        elif c == "1":
            try:
                url = input("URL: ").strip()
            except (EOFError, KeyboardInterrupt):
                continue
            if url:
                if load_page(state, url):
                    browser_loop(state)
                else:
                    pause()

        elif c == "2":
            try:
                q = input("Search query: ").strip()
            except (EOFError, KeyboardInterrupt):
                continue
            if q:
                if perform_search(state, q):
                    browser_loop(state)
                else:
                    pause()

        elif c == "3":
            choose_search_engine(state)

        elif c == "4":
            add_custom_engine(state)

        else:
            print("Invalid choice.")
            pause()


def main():
    browser_menu()


if __name__ == "__main__":
    main()
WEB_ENGINE_PY_EOF
        chmod 700 "$WEB_ENGINE_TARGET"
        print_ok "Created web_engine.py"
    fi

    # ============================================================
    # README - PROJECT DOCUMENTATION
    # ============================================================
    README_TARGET="README.md"

    if [ ! -f "$README_TARGET" ]; then
        cat > "$README_TARGET" << 'README_MD_EOF'
# 🤖 Termux AI v3.0

> **A complete AI-powered toolkit for Termux**

Copyright (c) 2026 Mr-Egyptian
Licensed under GNU General Public License v3.0
Original repository: <YOUR_REPO_URL>

---

## 📖 Overview

Termux AI is a comprehensive, single-file toolkit for Android's Termux terminal emulator. It bundles four powerful tools into one application:

1. **📁 Normal Mode** — Full-featured file manager
2. **🧠 Advanced Mode** — AI-powered command analyzer with 15+ API providers
3. **🌐 Browser** — Text-based web browser with download support
4. **💬 P2P Chat** — Encrypted peer-to-peer messenger with file sharing

The entire project is contained in a single `main.sh` file that self-bootstraps all required Python modules on first run — no complex installation needed.

---

## ✨ Features

### 📁 Normal Mode (12 options)

Complete file management with Arabic + English support:

| # | Feature |
|---|---------|
| 1 | Create File |
| 2 | Create Directory |
| 3 | Delete File |
| 4 | Delete Directory |
| 5 | Copy File/Directory |
| 6 | Move File/Directory |
| 7 | Rename File/Directory |
| 8 | List Directory |
| 9 | Read File |
| 10 | Search |
| 11 | Text Editor (nano) |
| 12 | File Browser |

**Locations supported:**
- Home directory (`$HOME`)
- Internal Storage (`~/storage/shared`)
- Downloads (`~/storage/shared/Download`)
- Documents (`~/storage/shared/Documents`)
- Custom path

**Safety:** Confirmation prompts before any destructive operation.

---

### 🧠 Advanced Mode (4 options)

| # | Feature |
|---|---------|
| 1 | Command Analyzer |
| 2 | Discover Commands |
| 3 | Auto-Learn Command |
| 4 | API Key Management |

#### Command Analyzer (8-Layer AI)

Automatically corrects mistyped commands using:

1. **Preprocessing** — Common abbreviations + typos
2. **Fuzzy Matching** — Sequence similarity
3. **Phonetic Matching** — Soundex-like algorithm
4. **Semantic Scoring** — Value type detection
5. **Structure Similarity** — Dynamic programming on syntax
6. **Record Scoring** — All database fields compared
7. **Context Awareness** — Package/Git/File/Network detection
8. **Learning from Usage** — Frequency-based boosting

**Database:** 200+ commands, 18 error patterns, 6 correction rules.

**Example:**
```

Input:  gti status
Output: git status
Score:  0.95 [high] very similar name

```

#### Supported AI Providers (15+)

| Provider | Model | Free |
|----------|-------|------|
| OpenAI | gpt-4o-mini | No |
| OpenRouter | qwen/qwen3.6-plus | No |
| Groq | llama-3.3-70b | Yes |
| Together AI | Llama 3.1 Turbo | No |
| DeepInfra | Meta-Llama 3.1 | No |
| Mistral | mistral-small | No |
| Cohere | command-r-plus | No |
| Cerebras | gpt-oss-120b | Yes |
| HuggingFace | Llama-3.2-3B | Yes |
| Google Gemini | gemini-flash | Yes |
| DeepSeek | deepseek-flash | Yes |
| xAI Grok | grok-4.1-fast | No |
| Anthropic | claude-sonnet | No |
| Perplexity | sonar-pro | No |
| Custom | Any OpenAI-compatible | - |

---

### 🌐 Browser (Text-based)

Full-featured text browser:

| # | Action |
|---|--------|
| 1 | Open link by number |
| 2 | Enter new URL |
| 3 | Search |
| 4 | Back |
| 5 | Reload |
| 6 | Change Search Engine |
| 7 | Next page |
| 8 | Previous page |
| 9 | Download by number |
| D | Download URL |
| 0 | Exit |

**Search Engines:**
- Bing (default — best for Arabic)
- Wikipedia
- Wiby
- DuckDuckGo Lite
- Custom engines (add your own)

**Features:**
- Progress bar for downloads
- Auto-detects file types
- GitHub releases to direct assets
- Cookie persistence
- Full Arabic support

---

### 💬 P2P Chat (Encrypted)

Peer-to-peer messaging over MQTT with strong encryption:

**Core Features:**
- AES-like encryption (PBKDF2 + SHA256 + HMAC)
- Friend requests with approval
- Live presence (online / away / offline)
- Group chats
- Small files (up to 256 KB)
- Large files via chunks (up to 20 MB)
- Remote command execution
- Offline message queue
- Chat history logging
- Emoji shortcuts

**Available Commands:**
```

/me                  Show your ID
/add NAME [ID]       Send friend request
/friends             List friends + status
/requests            Show pending requests
/accept NAME         Accept friend request
/reject NAME         Reject friend request
/remove NAME         Remove friend
/chat NAME           Open chat
/queue               Show offline queue
/cmd FRIEND CMD      Send command to friend
/file FRIEND PATH    Send file (max 20 MB)
/fileg GROUP PATH    Send file to group
/group               Groups menu
/g NAME              Open group chat
/help                Show help
/quit                Exit

```

---

## ⚡ Requirements

### Mandatory
```bash
- Android device
- Termux app (from F-Droid — recommended)
- bash
- python3
- python3-pip
```

For P2P Chat

```bash
pip install paho-mqtt
```

For Browser

No additional packages — uses Python's built-in urllib.

---

🚀 Installation

Method 1: Direct Copy

1. Copy main.sh to your Termux home directory:
   ```bash
   # If you downloaded it:
   mv ~/storage/downloads/main.sh ~/
   ```
2. Make it executable:
   ```bash
   chmod +x main.sh
   ```
3. Run it:
   ```bash
   ./main.sh
   ```

Method 2: From GitHub (future)

```bash
git clone <YOUR_REPO_URL>
cd TermuxAI
chmod +x main.sh
./main.sh
```

First Run

On the first run, bootstrap_files automatically creates:

· advanced_ai.py
· advanced_database.db
· api_config.json
· api_client.py
· p2p_chat.py
· web_engine.py
· README.md

No manual setup needed.

---

📚 Detailed Usage

Normal Mode

Simple file operations. Navigate the menu, choose a path, and manage files. All operations have confirmation prompts.

Advanced Mode

Command Analyzer:

```
> gti status

Found 1 suggestion:
  1. git status
     score: 0.95  [high] very similar name
     Distributed version control system
```

API Key Setup:

1. Choose [2] Advanced Mode then [4] API Key
2. Select [2] Select Provider and Model
3. Choose your provider (e.g., 10 for Google Gemini)
4. Add API key: [1] Add API Key
5. Test: [3] Test Connection
6. Chat: [4] Chat with Model

Browser

```
> Search: termux
> 1
> D
> Download URL: https://example.com/file.zip
```

P2P Chat

Setup (First Time):

1. Choose your username
2. Save your ID (like AHMED_AB12CD34)
3. Share it with friends

Connect with a friend:

```
/add sara SARA_XY98ZW76
```

Send a message:

```
/chat sara
> Hello Sara!
```

Send a file:

```
/file sara ~/document.pdf
```

Create a group:

```
/group create team
/group invite team sara
```

Send to group:

```
/g team
> Hello team!
```

Remote command:

```
/cmd sara whoami
```

---

🏗️ Architecture

```
main.sh (9200+ lines)
|
+-- bootstrap_files()
|   +-> advanced_ai.py        (~1000 lines)
|   +-> advanced_database.db  (~200 lines)
|   +-> api_config.json
|   +-> api_client.py         (~150 lines)
|   +-> p2p_chat.py           (~2500 lines)
|   +-> web_engine.py         (~1000 lines)
|   +-> README.md             (this file)
|
+-- UI functions
+-- Normal Mode functions
+-- Advanced Mode functions
+-- Browser functions
+-- P2P functions
+-- main_menu()
```

---

💡 Examples

Example 1: Correcting a Typo

```
$ ./main.sh
Select: 2                    # Advanced Mode
Select: 1                    # Command Analyzer
> lst

Found 2 suggestions:

  1. ls
     score: 0.92  [high] similar name
     List files and directories

  2. lst
     score: 0.50  [low] best match
```

Example 2: Sending a Large File

```
[Ahmed] > /file sara ~/video.mp4

Sending video.mp4 (5000000 bytes, 153 chunks)
  Sent: 153/153
File sent.

[Sara receives]
[FILE] from Ahmed: video.mp4 (5000000 bytes, 153 chunks)
  Receiving: 153/153
[FILE] from Ahmed: video.mp4 (5000000 bytes)
    Accept? [Y] Yes  [N] No
> Y

[OK] File accepted and saved.
```

Example 3: Quick Search

```
$ ./main.sh
Select: 3                    # Browser
Select: 2                    # Search
Search query: termux
```

---

🔧 Troubleshooting


Problem Solution
paho-mqtt not installed pip install paho-mqtt
Permission denied chmod +x main.sh
python3: not found pkg install python
Shared storage not available termux-setup-storage
Connection failed Check internet connection
AI file not found Run ./main.sh once to create files
Command failed with exit code Read error, check syntax

If P2P does not connect:

```bash
ping -c 3 broker.hivemq.com
```

If files are missing:

```bash
rm -f advanced_ai.py advanced_database.db p2p_chat.py web_engine.py api_client.py
./main.sh
```

---

🧪 Testing

Termux AI has been comprehensively tested:

Test Suite Passed
Bash syntax Yes
Python syntax (4 files) Yes
Normal Mode (12 features) Yes
Advanced Mode Yes
Browser Yes
P2P Chat (50 tests) 50/50
Encryption round-trip Yes
File chunking Yes
MD5 verification Yes

Test Coverage: 100%

---

⚠️ Limitations

Limit Value Reason
P2P file size 20 MB MQTT broker limits
Single file (no chunks) 256 KB Efficiency
Chunk size 32 KB Network balance
Remote command timeout 30 seconds Security
Chat log size Unlimited Storage-dependent

Security Notes

The current encryption provides:

· Protection against casual MQTT snooping
· Protection against unknown peers

Limitations:

· Shared salt is embedded in code
· Keys derived from public IDs
· MQTT broker is public

For maximum security: Avoid sharing sensitive data. Use a private MQTT broker for critical use.

---

🤝 Contributing

Contributions are welcome!

1. Fork the repository
2. Follow the existing code style
3. Test your changes thoroughly
4. Submit a Pull Request

Please note: Any modifications must:

· Include original copyright notice
· Credit the original author (Mr-Egyptian)
· Be open-sourced (GPL v3)

---

📜 License

GNU General Public License v3.0

Copyright (c) 2026 Mr-Egyptian

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program. If not, see https://www.gnu.org/licenses/

What This Means

You CAN:

· Use this software for any purpose
· Study how it works
· Modify it
· Share it with others

You MUST:

· Include this copyright notice in any copy
· Credit the original author (Mr-Egyptian)
· Open-source any modifications
· Include the license file

You CANNOT:

· Claim this as your own work
· Remove the copyright notice
· Include in proprietary software
· Sell without permission

For commercial use: please contact the author first.

---

👤 Author

Mr-Egyptian

· From Egypt
· Developer of Termux AI
· Contact: <mostafamom9292@gmail.com>
· GitHub: <YOUR_REPO_URL>

---

⚠️ Disclaimer

This software is provided "as is", without warranty of any kind, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose, and noninfringement. In no event shall the authors or copyright holders be liable for any claim, damages, or other liability, whether in an action of contract, tort, or otherwise, arising from, out of, or in connection with the software or the use or other dealings in the software.

Use at your own risk.

The P2P Chat feature uses a public MQTT broker. Messages may be accessible to third parties. Do not use for confidential communication.

The Browser feature downloads files from the internet. Ensure you trust the source before downloading.

---

🌟 Acknowledgments

· Termux — For the amazing Android terminal
· Paho MQTT — For the excellent MQTT client
· Open source community — For the tools that made this possible

---

📅 Version History

v3.0 (2026)

· Four complete modes: Normal, Advanced, Browser, P2P
· Encrypted P2P messaging
· Chunked file transfer (up to 20 MB)
· Text-based browser with downloads
· AI-powered command analyzer (8 layers)
· 15+ AI provider support
· Full Arabic support

---

Made with love in Egypt
README_MD_EOF
        print_ok "Created README.md"
    fi


}

choose_path() {
    while true
    do
        show_header

        printf "Choose a path:\n\n"
        printf "1. Home Directory\n"
        printf "2. Internal Storage\n"
        printf "3. Downloads\n"
        printf "4. Documents\n"
        printf "5. Custom Path\n"
        printf "0. Back\n\n"

        printf "Select: "
        read path_choice

        case "$path_choice" in
            1)
                SELECTED_PATH="$HOME"
                return 0
                ;;

            2)
                SELECTED_PATH="$HOME/storage/shared"
                return 0
                ;;

            3)
                SELECTED_PATH="$HOME/storage/shared/Download"
                return 0
                ;;

            4)
                SELECTED_PATH="$HOME/storage/shared/Documents"
                return 0
                ;;

            5)
                printf "\nEnter custom path: "
                read custom_path

                if [ -d "$custom_path" ]
                then
                    SELECTED_PATH="$custom_path"
                    return 0
                else
                    print_error "Directory does not exist."
                    pause_screen
                fi
                ;;

            0)
                return 1
                ;;

            *)
                print_error "Invalid choice."
                pause_screen
                ;;
        esac
    done
}
list_items() {
    LIST_DIR="$1"

    if [ ! -d "$LIST_DIR" ]
    then
        print_error "Directory does not exist."
        return 1
    fi

    ITEM_COUNT=0

    printf "\nDirectory: %s\n\n" "$LIST_DIR"

    for item in "$LIST_DIR"/*
    do
        [ -e "$item" ] || continue

        ITEM_COUNT=$((ITEM_COUNT + 1))
        ITEM_PATH="$item"
        ITEM_NAME="${item##*/}"

        if [ -d "$ITEM_PATH" ]
        then
            printf "%d. [DIR]  %s\n" "$ITEM_COUNT" "$ITEM_NAME"
        else
            printf "%d. [FILE] %s\n" "$ITEM_COUNT" "$ITEM_NAME"
        fi
    done

    if [ "$ITEM_COUNT" -eq 0 ]
    then
        printf "Directory is empty.\n"
    fi
}

select_item() {
LIST_DIR="$1"

    if [ ! -d "$LIST_DIR" ]
    then
        print_error "Directory does not exist."
        return 1
    fi

    ITEM_COUNT=0
    ITEM_PATHS="$TEMP_DIR/item_paths.txt"

    : > "$ITEM_PATHS"

    printf "\nDirectory: %s\n\n" "$LIST_DIR"

    for item in "$LIST_DIR"/*
    do
        [ -e "$item" ] || continue

        ITEM_COUNT=$((ITEM_COUNT + 1))

        printf "%s\n" "$item" >> "$ITEM_PATHS"

        ITEM_NAME="${item##*/}"

        if [ -d "$item" ]
        then
            printf "%d. [DIR]  %s\n" "$ITEM_COUNT" "$ITEM_NAME"
        else
            printf "%d. [FILE] %s\n" "$ITEM_COUNT" "$ITEM_NAME"
        fi
    done

    if [ "$ITEM_COUNT" -eq 0 ]
    then
        print_error "Directory is empty."
        return 1
    fi

    printf "\nSelect item number: "
    read item_choice

    case "$item_choice" in
        ''|*[!0-9]*)
            print_error "Invalid item number."
            return 1
            ;;
    esac

    if [ "$item_choice" -lt 1 ] || [ "$item_choice" -gt "$ITEM_COUNT" ]
    then
        print_error "Item number is out of range."
        return 1
    fi

    SELECTED_ITEM=$(sed -n "${item_choice}p" "$ITEM_PATHS")

    if [ -z "$SELECTED_ITEM" ]
    then
        print_error "Could not select the item."
        return 1
    fi

    return 0
}

create_file() {
    show_header

    printf "CREATE FILE\n"
    printf "------------\n\n"

    if ! choose_path
    then
        return
    fi

    printf "\nEnter file name: "
    read file_name

    if [ -z "$file_name" ]
    then
        print_error "File name cannot be empty."
        pause_screen
        return
    fi

    if [ -e "$SELECTED_PATH/$file_name" ]
    then
        print_error "A file or directory with this name already exists."
        pause_screen
        return
    fi

    if touch "$SELECTED_PATH/$file_name"
    then
        print_ok "File created successfully."
    else
        print_error "Failed to create file."
    fi

    pause_screen
}

create_directory() {
    show_header

    printf "CREATE DIRECTORY\n"
    printf "----------------\n\n"

    if ! choose_path
    then
        return
    fi

    printf "\nEnter directory name: "
    read directory_name

    if [ -z "$directory_name" ]
    then
        print_error "Directory name cannot be empty."
        pause_screen
        return
    fi

    if [ -e "$SELECTED_PATH/$directory_name" ]
    then
        print_error "A file or directory with this name already exists."
        pause_screen
        return
    fi

    if mkdir -p "$SELECTED_PATH/$directory_name"
    then
        print_ok "Directory created successfully."
    else
        print_error "Failed to create directory."
    fi

    pause_screen
}
delete_file() {
    show_header

    printf "DELETE FILE\n"
    printf '%s\n\n'  "-----------\n\n"

    if ! choose_path
    then
        return
    fi

    select_item "$SELECTED_PATH"

    if [ $? -ne 0 ]
    then
        pause_screen
        return
    fi

    if [ ! -f "$SELECTED_ITEM" ]
    then
        print_error "The selected item is not a file."
        pause_screen
        return
    fi

    printf "\nSelected file: %s\n" "${SELECTED_ITEM##*/}"
printf "Press ENTER to confirm deletion, or type anything to cancel: "
read confirm

if [ -z "$confirm" ]
then
  rm -f "$SELECTED_ITEM"
RM_STATUS=$?

if [ "$RM_STATUS" -eq 0 ] && [ ! -e "$SELECTED_ITEM" ]
then
    print_ok "File deleted successfully."
else
    print_error "Failed to delete file."
    printf "RM exit code: %s\n" "$RM_STATUS"
    printf "Target path:\n%s\n" "$SELECTED_ITEM"
fi	
    else
        print_info "Delete operation cancelled."
    fi

    pause_screen
}


delete_directory() {
    show_header

    printf "DELETE DIRECTORY\n"
    printf "----------------\n\n"

    if ! choose_path
    then
        return
    fi

    select_item "$SELECTED_PATH"

    if [ $? -ne 0 ]
    then
        pause_screen
        return
    fi

    if [ ! -d "$SELECTED_ITEM" ]
    then
        print_error "The selected item is not a directory."
        pause_screen
        return
    fi

    printf "\nSelected directory: %s\n" "${SELECTED_ITEM##*/}"
    printf "WARNING: This will delete the directory and everything inside it.\n"
   printf "Press ENTER to confirm deletion, or type anything to cancel: "
read confirm

if [ -z "$confirm" ]
then
     rm -rf "$SELECTED_ITEM"
RM_STATUS=$?

if [ "$RM_STATUS" -eq 0 ] && [ ! -e "$SELECTED_ITEM" ]
then
    print_ok "Directory deleted successfully."
else
    print_error "Failed to delete directory."
    printf "RM exit code: %s\n" "$RM_STATUS"
    printf "Target path:\n%s\n" "$SELECTED_ITEM"
fi
    else
        print_info "Delete operation cancelled."
    fi

    pause_screen
}
copy_item() {
    show_header

    printf "COPY FILE OR DIRECTORY\n"
    printf "---------------------\n\n"

    if ! choose_path
    then
        return
    fi

    select_item "$SELECTED_PATH"

    if [ $? -ne 0 ]
    then
        pause_screen
        return
    fi

    SOURCE="$SELECTED_ITEM"
    SOURCE_NAME="${SOURCE##*/}"

    printf "\nSelected: %s\n" "$SOURCE_NAME"

    printf "\nChoose destination path.\n\n"

    if ! choose_path
    then
        return
    fi

    DESTINATION="$SELECTED_PATH/$SOURCE_NAME"

    if [ -e "$DESTINATION" ]
    then
        print_error "An item with this name already exists at the destination."
        pause_screen
        return
    fi

    if [ -d "$SOURCE" ]
    then
        if cp -R "$SOURCE" "$DESTINATION"
        then
            print_ok "Directory copied successfully."
        else
            print_error "Failed to copy directory."
        fi
    else
        if cp "$SOURCE" "$DESTINATION"
        then
            print_ok "File copied successfully."
        else
            print_error "Failed to copy file."
        fi
    fi

    pause_screen
}


move_item() {
    show_header

    printf "MOVE FILE OR DIRECTORY\n"
    printf "---------------------\n\n"

    if ! choose_path
    then
        return
    fi

    select_item "$SELECTED_PATH"

    if [ $? -ne 0 ]
    then
        pause_screen
        return
    fi

    SOURCE="$SELECTED_ITEM"
    SOURCE_NAME="${SOURCE##*/}"

    printf "\nSelected: %s\n" "$SOURCE_NAME"

    printf "\nChoose destination path.\n\n"

    if ! choose_path
    then
        return
    fi

    DESTINATION="$SELECTED_PATH/$SOURCE_NAME"

    if [ -e "$DESTINATION" ]
    then
        print_error "An item with this name already exists at the destination."
        pause_screen
        return
    fi

    if mv "$SOURCE" "$DESTINATION"
    then
        print_ok "Item moved successfully."
    else
        print_error "Failed to move item."
    fi

    pause_screen
}
rename_item() {
    show_header

    printf "RENAME FILE OR DIRECTORY\n"
    printf "-----------------------\n\n"

    if ! choose_path
    then
        return
    fi

    select_item "$SELECTED_PATH"

    if [ $? -ne 0 ]
    then
        pause_screen
        return
    fi

    OLD_PATH="$SELECTED_ITEM"
    OLD_NAME="${OLD_PATH##*/}"

    printf "\nCurrent name: %s\n" "$OLD_NAME"
    printf "Enter new name: "
    read NEW_NAME

    if [ -z "$NEW_NAME" ]
    then
        print_error "New name cannot be empty."
        pause_screen
        return
    fi

    NEW_PATH="$SELECTED_PATH/$NEW_NAME"

    if [ -e "$NEW_PATH" ]
    then
        print_error "An item with this name already exists."
        pause_screen
        return
    fi

    if mv "$OLD_PATH" "$NEW_PATH"
    then
        print_ok "Renamed successfully."
    else
        print_error "Failed to rename item."
    fi

    pause_screen
}


list_directory() {
    show_header

    printf "LIST DIRECTORY\n"
    printf "--------------\n\n"

    if ! choose_path
    then
        return
    fi

    list_items "$SELECTED_PATH"

    pause_screen
}


read_file() {
    show_header

    printf "READ FILE\n"
    printf '%s\n\n' "---------\n\n"

    if ! choose_path
    then
        return
    fi

    select_item "$SELECTED_PATH"

    if [ $? -ne 0 ]
    then
        pause_screen
        return
    fi

    if [ ! -f "$SELECTED_ITEM" ]
    then
        print_error "The selected item is not a file."
        pause_screen
        return
    fi

    printf "\n====================================\n"
    printf "File: %s\n" "${SELECTED_ITEM##*/}"
    printf "====================================\n\n"

    cat "$SELECTED_ITEM"

    printf "\n\n====================================\n"

    pause_screen
}

browse_directory() {
CURRENT_DIR="$1"

    while true
    do
        show_header

        printf "BROWSE DIRECTORY\n"
        printf '%s\n\n' "----------------"

        printf "Current directory:\n%s\n\n" "$CURRENT_DIR"

        ITEM_COUNT=0
        BROWSE_LIST="$TEMP_DIR/browse_list.txt"

        : > "$BROWSE_LIST"

        for item in "$CURRENT_DIR"/*
        do
            [ -e "$item" ] || continue

            ITEM_COUNT=$((ITEM_COUNT + 1))

            printf "%s\n" "$item" >> "$BROWSE_LIST"

            ITEM_NAME="${item##*/}"

            if [ -d "$item" ]
            then
                printf "%d. [DIR]  %s\n" "$ITEM_COUNT" "$ITEM_NAME"
            else
                printf "%d. [FILE] %s\n" "$ITEM_COUNT" "$ITEM_NAME"
            fi
        done

        if [ "$ITEM_COUNT" -eq 0 ]
        then
            printf "Directory is empty.\n"
        fi

        printf "\n0. Back\n\n"
        printf "Select: "
        read browse_choice

        if [ "$browse_choice" = "0" ]
        then
            return
        fi

        case "$browse_choice" in
            ''|*[!0-9]*)
                print_error "Invalid choice."
                pause_screen
                continue
                ;;
        esac

        if [ "$browse_choice" -lt 1 ] || [ "$browse_choice" -gt "$ITEM_COUNT" ]
        then
            print_error "Item number is out of range."
            pause_screen
            continue
        fi

        SELECTED_BROWSE_ITEM=$(sed -n "${browse_choice}p" "$BROWSE_LIST")

        if [ -d "$SELECTED_BROWSE_ITEM" ]
        then
            CURRENT_DIR="$SELECTED_BROWSE_ITEM"
        else
            while true
            do
                show_header

                printf "SELECTED FILE\n"
                printf '%s\n\n' "-------------"

                printf "%s\n\n" "$SELECTED_BROWSE_ITEM"

                printf "1. Read File\n"
                printf "2. Delete File\n"
                printf "3. Open in Text Editor\n"
                printf "0. Back\n\n"

                printf "Select: "
                read file_action

                case "$file_action" in
                    1)
                        clear_screen

                        printf "FILE: %s\n" "$SELECTED_BROWSE_ITEM"
                        printf '%s\n\n' "--------------------------------"

                        cat "$SELECTED_BROWSE_ITEM"

                        printf "\n\n"
                        pause_screen
                        ;;

                    2)
                        printf "\nSelected file: %s\n" "${SELECTED_BROWSE_ITEM##*/}"
                        printf "Press ENTER to confirm deletion, or type anything to cancel: "
                        read confirm

                        if [ -z "$confirm" ]
                        then
                            rm -f "$SELECTED_BROWSE_ITEM"
                            RM_STATUS=$?

                            if [ "$RM_STATUS" -eq 0 ] && [ ! -e "$SELECTED_BROWSE_ITEM" ]
                            then
                                print_ok "File deleted successfully."
                            else
                                print_error "Failed to delete file."
                                printf "RM exit code: %s\n" "$RM_STATUS"
                            fi
                        else
                            print_info "Delete operation cancelled."
                        fi

                        pause_screen
                        ;;

                    3)
                        nano "$SELECTED_BROWSE_ITEM"
                        ;;

                    0)
                        break
                        ;;

                    *)
                        print_error "Invalid choice."
                        pause_screen
                        ;;
                esac
            done
        fi
    done
}
text_editor() {
if [ -n "${1:-}" ]
    then
        if [ ! -f "$1" ]
        then
            print_error "The selected item is not a file."
            pause_screen
            return 1
        fi

        nano "$1"
        return 0
    fi

    show_header

    printf "TEXT EDITOR\n"
    printf '%s\n\n' "-----------"

    if ! choose_path
    then
        return
    fi

    select_item "$SELECTED_PATH"

    if [ $? -ne 0 ]
    then
        pause_screen
        return
    fi

    if [ ! -f "$SELECTED_ITEM" ]
    then
        print_error "The selected item is not a file."
        pause_screen
        return
    fi

    nano "$SELECTED_ITEM"
}
search_items() {
    show_header

    printf "SEARCH\n"
    printf "------\n\n"

    if ! choose_path
    then
        return
    fi

    SEARCH_ROOT="$SELECTED_PATH"

    printf "\nSearch location:\n%s\n\n" "$SEARCH_ROOT"

    printf "Enter name to search for: "
    read search_name

    if [ -z "$search_name" ]
    then
        print_error "Search name cannot be empty."
        pause_screen
        return
    fi

    SEARCH_RESULTS="$TEMP_DIR/search_results.txt"

    : > "$SEARCH_RESULTS"

    printf "\nSearching...\n\n"

    find "$SEARCH_ROOT" -name "*$search_name*" 2>/dev/null > "$SEARCH_RESULTS"

    if [ ! -s "$SEARCH_RESULTS" ]
    then
        print_info "No matching files or directories found."
        pause_screen
        return
    fi

    while true
    do
        show_header

        printf "SEARCH RESULTS\n"
        printf "--------------\n\n"

        SEARCH_COUNT=0

        while IFS= read -r result
        do
            SEARCH_COUNT=$((SEARCH_COUNT + 1))

            if [ -d "$result" ]
            then
                printf "%d. [DIR]  %s\n" "$SEARCH_COUNT" "$result"
            else
                printf "%d. [FILE] %s\n" "$SEARCH_COUNT" "$result"
            fi
        done < "$SEARCH_RESULTS"

        printf "\nFound %d result(s).\n\n" "$SEARCH_COUNT"

        printf "0. Back\n\n"
        printf "Select result: "
        read search_choice

        if [ "$search_choice" = "0" ]
        then
            return
        fi

        case "$search_choice" in
            ''|*[!0-9]*)
                print_error "Invalid result number."
                pause_screen
                continue
                ;;
        esac

        if [ "$search_choice" -lt 1 ] || [ "$search_choice" -gt "$SEARCH_COUNT" ]
        then
            print_error "Result number is out of range."
            pause_screen
            continue
        fi

        SELECTED_SEARCH_RESULT=$(sed -n "${search_choice}p" "$SEARCH_RESULTS")

        if [ -z "$SELECTED_SEARCH_RESULT" ]
        then
            print_error "Could not select the result."
            pause_screen
            continue
        fi

        if [ -f "$SELECTED_SEARCH_RESULT" ]
        then
            while true
            do
                show_header

                printf "SELECTED FILE\n"
                printf "-------------\n\n"
                printf "%s\n\n" "$SELECTED_SEARCH_RESULT"

                printf "1. Read File\n"
                printf "2. Delete File\n"
                printf "3. Open in Text Editor\n"
                printf "0. Back\n\n"

                printf "Select: "
                read file_action

                case "$file_action" in
                    1)
                        clear_screen
                        printf "FILE: %s\n" "$SELECTED_SEARCH_RESULT"
                        printf "--------------------------------\n\n"

                        cat "$SELECTED_SEARCH_RESULT"

                        printf "\n\n"
                        pause_screen
                        ;;

                    2)
                        printf "\nSelected file: %s\n" "${SELECTED_SEARCH_RESULT##*/}"
                        printf "Press ENTER to confirm deletion, or type anything to cancel: "
                        read confirm

                        if [ -z "$confirm" ]
                        then
                            rm -f "$SELECTED_SEARCH_RESULT"
                            RM_STATUS=$?

                            if [ "$RM_STATUS" -eq 0 ] && [ ! -e "$SELECTED_SEARCH_RESULT" ]
                            then
                                print_ok "File deleted successfully."

                                sed -i "\|^$SELECTED_SEARCH_RESULT$|d" "$SEARCH_RESULTS"
                            else
                                print_error "Failed to delete file."
                                printf "RM exit code: %s\n" "$RM_STATUS"
                            fi
                        else
                            print_info "Delete operation cancelled."
                        fi

                        pause_screen
                        ;;

3)
    nano "$SELECTED_SEARCH_RESULT"
    ;;

                    0)
                        break
                        ;;

                    *)
                        print_error "Invalid choice."
                        pause_screen
                        ;;
                esac
            done

        elif [ -d "$SELECTED_SEARCH_RESULT" ]
        then
            while true
            do
                show_header

                printf "SELECTED DIRECTORY\n"
                printf "------------------\n\n"
                printf "%s\n\n" "$SELECTED_SEARCH_RESULT"

                printf "1. Open Directory\n"
                printf "2. Delete Directory\n"
                printf "0. Back\n\n"

                printf "Select: "
                read directory_action

                case "$directory_action" in
                   1)
    browse_directory "$SELECTED_SEARCH_RESULT"
    ;;                   2)
                        printf "\nSelected directory: %s\n" "${SELECTED_SEARCH_RESULT##*/}"
                        printf "WARNING: This will delete the directory and everything inside it.\n"
                        printf "Press ENTER to confirm deletion, or type anything to cancel: "
                        read confirm

                        if [ -z "$confirm" ]
                        then
                            rm -rf "$SELECTED_SEARCH_RESULT"
                            RM_STATUS=$?

                            if [ "$RM_STATUS" -eq 0 ] && [ ! -e "$SELECTED_SEARCH_RESULT" ]
                            then
                                print_ok "Directory deleted successfully."

                                sed -i "\|^$SELECTED_SEARCH_RESULT$|d" "$SEARCH_RESULTS"
                            else
                                print_error "Failed to delete directory."
                                printf "RM exit code: %s\n" "$RM_STATUS"
                            fi
                        else
                            print_info "Delete operation cancelled."
                        fi

                        pause_screen
                        ;;

                    0)
                        break
                        ;;

                    *)
                        print_error "Invalid choice."
                        pause_screen
                        ;;
                esac
            done
        else
            print_error "The selected result no longer exists."
            pause_screen
        fi
    done
}
normal_mode() {
    while true
    do
        show_header

        printf "NORMAL MODE\n"
        printf '%s\n\n'  "-----------\n\n"

        printf "1. Create File\n"
        printf "2. Create Directory\n"
        printf "3. Delete File\n"
        printf "4. Delete Directory\n"
        printf "5. Copy File/Directory\n"
        printf "6. Move File/Directory\n"
        printf "7. Rename File/Directory\n"
        printf "8. List Directory\n"
        printf "9. Read File\n"
        printf "10. Search\n"
	printf "11. Text Editor\n"
        printf "12. File Browser\n"
        printf "0. Back\n\n"

        printf "Select: "
        read normal_choice

        case "$normal_choice" in
            1)
                create_file
                ;;

            2)
                create_directory
                ;;

            3)
                delete_file
                ;;

            4)
                delete_directory
                ;;

            5)
                copy_item
                ;;

            6)
                move_item
                ;;
            7)
                rename_item
                ;;

            8)
                list_directory
                ;;

            9)
                read_file
                ;;

            10)
                search_items
                ;;
            11)
                text_editor
                ;;
            12)
                file_browser
                ;;
            0)
                return
                ;;

            *)
                print_error "Invalid choice."
                pause_screen
                ;;
        esac
    done
}
analyze_error() {
    ERROR_TEXT="$1"

    printf "\nERROR ANALYSIS\n"
    printf "--------------\n"

    case "$ERROR_TEXT" in
        *"not found"*)
            printf "Possible cause: The command does not exist or is not installed.\n"
            printf "Suggestion: Check the command name or install the required package.\n"
            ;;

        *"No such file or directory"*)
            printf "Possible cause: The specified file or directory does not exist.\n"
            printf "Suggestion: Check the path and spelling.\n"
            ;;

        *"Permission denied"*)
            printf "Possible cause: You do not have permission to access this item.\n"
            printf "Suggestion: Check the file permissions and storage permissions.\n"
            ;;

        *"Not a directory"*)
            printf "Possible cause: A file was used where a directory was expected.\n"
            printf "Suggestion: Check the path.\n"
            ;;

        *"Is a directory"*)
            printf "Possible cause: A directory was used where a file was expected.\n"
            printf "Suggestion: Check the selected item.\n"
            ;;

        *"Syntax error"*)
            printf "Possible cause: The shell command contains invalid syntax.\n"
            printf "Suggestion: Check quotes, brackets, operators, and command structure.\n"
            ;;

        *"invalid option"*)
            printf "Possible cause: An unsupported command option was used.\n"
            printf "Suggestion: Check the command help with: command --help\n"
            ;;

        *)
            printf "No specific analysis was found for this error.\n"
            printf "Review the error message above and check the command.\n"
            ;;
    esac
}
file_browser()
{
    while true
    do
        clear

        echo "FILE BROWSER"
        echo "--------------------------------"
        echo "1. Private Termux Storage"
        echo "2. Shared Internal Storage"
        echo "0. Back"
        echo

        printf "Select: "
        read -r STORAGE_CHOICE

        case "$STORAGE_CHOICE" in

            1)
                CURRENT_DIR="$HOME"
                ROOT_DIR="$HOME"
                ;;

            2)
                if [ ! -d "$HOME/storage/shared" ]
                then
                    echo
                    echo "Shared storage is not available."
                    echo "Run: termux-setup-storage"
                    echo
                    printf "Press ENTER to continue..."
                    read
                    continue
                fi

                CURRENT_DIR="$HOME/storage/shared"
                ROOT_DIR="$HOME/storage/shared"
                ;;

            0)
                return
                ;;

            *)
                echo
                echo "Invalid choice."
                printf "Press ENTER to continue..."
                read
                continue
                ;;
        esac

        while true
        do
            clear

            echo "FILE BROWSER"
            echo "--------------------------------"
            echo "Current directory:"
            echo "$CURRENT_DIR"
            echo "--------------------------------"
            echo

            ITEM_COUNT=0
            BROWSER_LIST="$HOME/.file_browser_list"

            : > "$BROWSER_LIST"

            for ITEM in "$CURRENT_DIR"/*
            do
                [ -e "$ITEM" ] || continue

                ITEM_COUNT=$((ITEM_COUNT + 1))

                printf "%s\n" "$ITEM" >> "$BROWSER_LIST"

                ITEM_NAME="${ITEM##*/}"

                if [ -d "$ITEM" ]
                then
                    printf "%d. [DIR]  %s\n" \
                        "$ITEM_COUNT" "$ITEM_NAME"
                else
                    printf "%d. [FILE] %s\n" \
                        "$ITEM_COUNT" "$ITEM_NAME"
                fi
            done

            if [ "$ITEM_COUNT" -eq 0 ]
            then
                echo "Directory is empty."
            fi

            echo
            echo "0. Use This Directory"
            echo "A. Directory Actions"

            if [ "$CURRENT_DIR" != "$ROOT_DIR" ]
            then
                echo "C. Copy This Directory"
                echo "M. Move This Directory"
                echo "R. Rename This Directory"
                echo "D. Delete This Directory"
            fi

            echo "B. Go Back"
            echo "S. Change Storage"
            echo

            printf "Select: "
            read -r BROWSER_CHOICE

            case "$BROWSER_CHOICE" in

                0)
                    SELECTED_DESTINATION="$CURRENT_DIR"
                    return 0
                    ;;

                [Aa])
                    directory_actions "$CURRENT_DIR"
                    ;;

                [Cc])
                    if [ "$CURRENT_DIR" = "$ROOT_DIR" ]
                    then
                        echo
                        echo "The storage root cannot be copied this way."
                        printf "Press ENTER to continue..."
                        read
                        continue
                    fi

                    clear

                    echo "COPY DIRECTORY"
                    echo "--------------------------------"
                    echo "Source:"
                    echo "$CURRENT_DIR"
                    echo

                    storage_selector

                    if [ $? -ne 0 ]
                    then
                        echo
                        echo "Copy cancelled."
                        printf "Press ENTER to continue..."
                        read
                        continue
                    fi

                    destination_browser "$SELECTED_STORAGE_ROOT"

                    if [ $? -ne 0 ]
                    then
                        echo
                        echo "Copy cancelled."
                        printf "Press ENTER to continue..."
                        read
                        continue
                    fi

                    DIRECTORY_TARGET="$SELECTED_DESTINATION/$(basename "$CURRENT_DIR")"

                    case "$DIRECTORY_TARGET/" in
                        "$CURRENT_DIR/"*)
                            echo
                            echo "You cannot copy a directory into itself."
                            printf "Press ENTER to continue..."
                            read
                            continue
                            ;;
                    esac

                    if [ "$DIRECTORY_TARGET" = "$CURRENT_DIR" ]
                    then
                        echo
                        echo "Source and destination are the same."
                        printf "Press ENTER to continue..."
                        read
                        continue
                    fi

                    if [ -e "$DIRECTORY_TARGET" ]
                    then
                        echo
                        echo "A directory with the same name already exists."
                        echo
                        printf "Replace it? (y/n): "
                        read -r OVERWRITE

                        case "$OVERWRITE" in
                            y|Y)
                                rm -rf "$DIRECTORY_TARGET"
                                ;;
                            *)
                                echo
                                echo "Copy cancelled."
                                printf "Press ENTER to continue..."
                                read
                                continue
                                ;;
                        esac
                    fi

                    cp -rf "$CURRENT_DIR" "$DIRECTORY_TARGET"

                    if [ $? -eq 0 ]
                    then
                        echo
                        echo "Directory copied successfully."
                    else
                        echo
                        echo "Failed to copy directory."
                    fi

                    printf "Press ENTER to continue..."
                    read
                    ;;

                [Mm])
                    if [ "$CURRENT_DIR" = "$ROOT_DIR" ]
                    then
                        echo
                        echo "The storage root cannot be moved."
                        printf "Press ENTER to continue..."
                        read
                        continue
                    fi

                    clear

                    echo "MOVE DIRECTORY"
                    echo "--------------------------------"
                    echo "Source:"
                    echo "$CURRENT_DIR"
                    echo

                    storage_selector

                    if [ $? -ne 0 ]
                    then
                        echo
                        echo "Move cancelled."
                        printf "Press ENTER to continue..."
                        read
                        continue
                    fi

                    destination_browser "$SELECTED_STORAGE_ROOT"

                    if [ $? -ne 0 ]
                    then
                        echo
                        echo "Move cancelled."
                        printf "Press ENTER to continue..."
                        read
                        continue
                    fi

                    DIRECTORY_TARGET="$SELECTED_DESTINATION/$(basename "$CURRENT_DIR")"

                    case "$DIRECTORY_TARGET/" in
                        "$CURRENT_DIR/"*)
                            echo
                            echo "You cannot move a directory into itself."
                            printf "Press ENTER to continue..."
                            read
                            continue
                            ;;
                    esac

                    if [ "$DIRECTORY_TARGET" = "$CURRENT_DIR" ]
                    then
                        echo
                        echo "Source and destination are the same."
                        printf "Press ENTER to continue..."
                        read
                        continue
                    fi

                    if [ -e "$DIRECTORY_TARGET" ]
                    then
                        echo
                        echo "A directory with the same name already exists."
                        echo
                        printf "Replace it? (y/n): "
                        read -r OVERWRITE

                        case "$OVERWRITE" in
                            y|Y)
                                rm -rf "$DIRECTORY_TARGET"
                                ;;
                            *)
                                echo
                                echo "Move cancelled."
                                printf "Press ENTER to continue..."
                                read
                                continue
                                ;;
                        esac
                    fi

                    PARENT_DIRECTORY="${CURRENT_DIR%/*}"

                    if [ -z "$PARENT_DIRECTORY" ]
                    then
                        PARENT_DIRECTORY="/"
                    fi

                    mv "$CURRENT_DIR" "$DIRECTORY_TARGET"

                    if [ $? -eq 0 ]
                    then
                        echo
                        echo "Directory moved successfully."
                        CURRENT_DIR="$PARENT_DIRECTORY"
                    else
                        echo
                        echo "Failed to move directory."
                    fi

                    printf "Press ENTER to continue..."
                    read
                    ;;

                [Rr])
                    if [ "$CURRENT_DIR" = "$ROOT_DIR" ]
                    then
                        echo
                        echo "The storage root cannot be renamed."
                        printf "Press ENTER to continue..."
                        read
                        continue
                    fi

                    clear

                    echo "RENAME DIRECTORY"
                    echo "--------------------------------"
                    echo "Current name:"
                    echo "$(basename "$CURRENT_DIR")"
                    echo "--------------------------------"
                    echo

                    printf "Enter new name: "
                    read -r NEW_NAME

                    if [ -z "$NEW_NAME" ]
                    then
                        echo
                        echo "Rename cancelled."
                        printf "Press ENTER to continue..."
                        read
                        continue
                    fi

                    CURRENT_NAME="$(basename "$CURRENT_DIR")"
                    PARENT_DIR="$(dirname "$CURRENT_DIR")"
                    NEW_PATH="$PARENT_DIR/$NEW_NAME"

                    if [ "$NEW_NAME" = "$CURRENT_NAME" ]
                    then
                        echo
                        echo "The new name is the same as the current name."
                        echo "Rename cancelled."
                        printf "Press ENTER to continue..."
                        read
                        continue
                    fi

                    case "$NEW_NAME" in
                        */*)
                            echo
                            echo "Invalid name."
                            echo "The name cannot contain /"
                            printf "Press ENTER to continue..."
                            read
                            continue
                            ;;
                    esac

                    if [ "$NEW_NAME" = "." ] || [ "$NEW_NAME" = ".." ]
                    then
                        echo
                        echo "Invalid name."
                        printf "Press ENTER to continue..."
                        read
                        continue
                    fi

                    if [ -e "$NEW_PATH" ] || [ -L "$NEW_PATH" ]
                    then
                        echo
                        echo "An item with this name already exists."
                        echo "Rename cancelled."
                        printf "Press ENTER to continue..."
                        read
                        continue
                    fi

                    mv "$CURRENT_DIR" "$NEW_PATH"

                    if [ $? -eq 0 ]
                    then
                        echo
                        echo "Directory renamed successfully."
                        CURRENT_DIR="$NEW_PATH"
                    else
                        echo
                        echo "Failed to rename directory."
                    fi

                    printf "Press ENTER to continue..."
                    read
                    ;;

                [Dd])
                    if [ "$CURRENT_DIR" = "$ROOT_DIR" ]
                    then
                        echo
                        echo "The storage root cannot be deleted."
                        printf "Press ENTER to continue..."
                        read
                        continue
                    fi

                    clear

                    echo "DELETE DIRECTORY"
                    echo "--------------------------------"
                    echo "$CURRENT_DIR"
                    echo "--------------------------------"
                    echo
                    echo "All files inside this directory will also be deleted."
                    echo
                    printf "Press ENTER to delete this directory."
                    echo
                    printf "Or type N then press ENTER to cancel: "

                    read -r DELETE_CONFIRM

                    if [ -z "$DELETE_CONFIRM" ]
                    then
                        PARENT_DIRECTORY="${CURRENT_DIR%/*}"

                        if [ -z "$PARENT_DIRECTORY" ]
                        then
                            PARENT_DIRECTORY="/"
                        fi

                        rm -rf "$CURRENT_DIR"

                        if [ $? -eq 0 ]
                        then
                            echo
                            echo "Directory deleted successfully."
                            CURRENT_DIR="$PARENT_DIRECTORY"
                        else
                            echo
                            echo "Failed to delete directory."
                        fi
                    else
                        echo
                        echo "Deletion cancelled."
                    fi

                    printf "Press ENTER to continue..."
                    read
                    ;;

                [Bb])
                    if [ "$CURRENT_DIR" = "$ROOT_DIR" ]
                    then
                        break
                    fi

                    CURRENT_DIR="${CURRENT_DIR%/*}"

                    if [ -z "$CURRENT_DIR" ]
                    then
                        CURRENT_DIR="/"
                    fi
                    ;;

                [Ss])
                    break
                    ;;

                ''|*[!0-9]*)
                    echo
                    echo "Invalid choice."
                    printf "Press ENTER to continue..."
                    read
                    ;;

                *)
                    if [ "$BROWSER_CHOICE" -lt 1 ] ||
                       [ "$BROWSER_CHOICE" -gt "$ITEM_COUNT" ]
                    then
                        echo
                        echo "Item number is out of range."
                        printf "Press ENTER to continue..."
                        read
                        continue
                    fi

                    SELECTED_ITEM=$(sed -n "${BROWSER_CHOICE}p" "$BROWSER_LIST")

                    if [ -d "$SELECTED_ITEM" ]
                    then
                        CURRENT_DIR="$SELECTED_ITEM"
                    else
                        file_actions "$SELECTED_ITEM"

                        if [ ! -e "$SELECTED_ITEM" ]
                        then
                            continue
                        fi
                    fi
                    ;;
            esac
        done
    done
}
file_actions()
{
    SELECTED_FILE="$1"

    while true
    do
        clear

        echo "FILE ACTIONS"
        echo "--------------------------------"
        echo "Selected file:"
        echo "$SELECTED_FILE"
        echo "--------------------------------"
        echo
        echo "1. Read File"
        echo "2. Open in Text Editor"
        echo "3. Copy File"
        echo "4. Move File"
        echo "5. Delete File"
        echo "6. File Information"
        echo "7. Rename File"
        echo "0. Back"
        echo

        printf "Select: "
        read -r FILE_ACTION

        case "$FILE_ACTION" in

            1)
                clear

                echo "FILE CONTENT"
                echo "--------------------------------"
                echo "$SELECTED_FILE"
                echo "--------------------------------"
                echo

                cat "$SELECTED_FILE"

                echo
                echo
                printf "Press ENTER to continue..."
                read
                ;;

            2)
                nano "$SELECTED_FILE"
                ;;

            3)
                clear

                echo "COPY FILE"
                echo "--------------------------------"
                echo "Source:"
                echo "$SELECTED_FILE"
                echo

                storage_selector

                if [ $? -ne 0 ]
                then
                    echo
                    echo "Copy cancelled."
                    printf "Press ENTER to continue..."
                    read
                    continue
                fi

                destination_browser "$SELECTED_STORAGE_ROOT"

                if [ $? -ne 0 ]
                then
                    echo
                    echo "Copy cancelled."
                    printf "Press ENTER to continue..."
                    read
                    continue
                fi

                COPY_TARGET="$SELECTED_DESTINATION/$(basename "$SELECTED_FILE")"

                if [ -e "$COPY_TARGET" ]
                then
                    echo
                    echo "A file with the same name already exists."
                    echo
                    printf "Overwrite? (y/n): "
                    read -r OVERWRITE

                    case "$OVERWRITE" in
                        y|Y)
                            ;;
                        *)
                            echo
                            echo "Copy cancelled."
                            printf "Press ENTER to continue..."
                            read
                            continue
                            ;;
                    esac
                fi

                cp -f "$SELECTED_FILE" "$COPY_TARGET"

                if [ $? -eq 0 ]
                then
                    echo
                    echo "File copied successfully."
                else
                    echo
                    echo "Failed to copy file."
                fi

                printf "Press ENTER to continue..."
                read
                ;;

            4)
                clear

                echo "MOVE FILE"
                echo "--------------------------------"
                echo "Source:"
                echo "$SELECTED_FILE"
                echo

                storage_selector

                if [ $? -ne 0 ]
                then
                    echo
                    echo "Move cancelled."
                    printf "Press ENTER to continue..."
                    read
                    continue
                fi

                destination_browser "$SELECTED_STORAGE_ROOT"

                if [ $? -ne 0 ]
                then
                    echo
                    echo "Move cancelled."
                    printf "Press ENTER to continue..."
                    read
                    continue
                fi

                MOVE_TARGET="$SELECTED_DESTINATION/$(basename "$SELECTED_FILE")"

                if [ -e "$MOVE_TARGET" ]
                then
                    echo
                    echo "A file with the same name already exists."
                    echo
                    printf "Overwrite? (y/n): "
                    read -r OVERWRITE

                    case "$OVERWRITE" in
                        y|Y)
                            ;;
                        *)
                            echo
                            echo "Move cancelled."
                            printf "Press ENTER to continue..."
                            read
                            continue
                            ;;
                    esac
                fi

                mv -f "$SELECTED_FILE" "$MOVE_TARGET"

                if [ $? -eq 0 ]
                then
                    echo
                    echo "File moved successfully."
                    printf "Press ENTER to continue..."
                    read
                    return
                else
                    echo
                    echo "Failed to move file."
                fi

                printf "Press ENTER to continue..."
                read
                ;;

            5)
                clear

                echo "DELETE FILE"
                echo "--------------------------------"
                echo "$SELECTED_FILE"
                echo "--------------------------------"
                echo
                printf "Press ENTER to delete this file."
                echo
                printf "Or type N then press ENTER to cancel: "

                read -r DELETE_CONFIRM

                if [ -z "$DELETE_CONFIRM" ]
                then
                    rm -f "$SELECTED_FILE"

                    if [ $? -eq 0 ]
                    then
                        echo
                        echo "File deleted successfully."
                        printf "Press ENTER to continue..."
                        read
                        return
                    else
                        echo
                        echo "Failed to delete file."
                    fi
                else
                    echo
                    echo "Deletion cancelled."
                fi

                printf "Press ENTER to continue..."
                read
                ;;

            6)
                clear

                echo "FILE INFORMATION"
                echo "--------------------------------"
                echo "Path:"
                echo "$SELECTED_FILE"
                echo

                echo "Name:"
                echo "$(basename "$SELECTED_FILE")"
                echo

                if [ -f "$SELECTED_FILE" ]
                then
                    echo "Type: Regular File"
                fi

                if [ -r "$SELECTED_FILE" ]
                then
                    echo "Readable: Yes"
                else
                    echo "Readable: No"
                fi

                if [ -w "$SELECTED_FILE" ]
                then
                    echo "Writable: Yes"
                else
                    echo "Writable: No"
                fi

                if [ -x "$SELECTED_FILE" ]
                then
                    echo "Executable: Yes"
                else
                    echo "Executable: No"
                fi

                if command -v stat >/dev/null 2>&1
                then
                    FILE_SIZE=$(stat -c "%s" "$SELECTED_FILE" 2>/dev/null)

                    if [ -n "$FILE_SIZE" ]
                    then
                        echo "Size: $FILE_SIZE bytes"
                    fi
                fi

                echo
                printf "Press ENTER to continue..."
                read
                ;;

            7)
                clear

                echo "RENAME FILE"
                echo "--------------------------------"
                echo "Current name:"
                echo "$(basename "$SELECTED_FILE")"
                echo "--------------------------------"
                echo

                printf "Enter new name: "
                read -r NEW_NAME

                if [ -z "$NEW_NAME" ]
                then
                    echo
                    echo "Rename cancelled."
                    printf "Press ENTER to continue..."
                    read
                    continue
                fi

                CURRENT_NAME="$(basename "$SELECTED_FILE")"
                PARENT_DIR="$(dirname "$SELECTED_FILE")"
                NEW_PATH="$PARENT_DIR/$NEW_NAME"

                if [ "$NEW_NAME" = "$CURRENT_NAME" ]
                then
                    echo
                    echo "The new name is the same as the current name."
                    echo "Rename cancelled."
                    printf "Press ENTER to continue..."
                    read
                    continue
                fi

                case "$NEW_NAME" in
                    */*)
                        echo
                        echo "Invalid name."
                        echo "The name cannot contain /"
                        printf "Press ENTER to continue..."
                        read
                        continue
                        ;;
                esac

                if [ "$NEW_NAME" = "." ] || [ "$NEW_NAME" = ".." ]
                then
                    echo
                    echo "Invalid name."
                    printf "Press ENTER to continue..."
                    read
                    continue
                fi

                if [ -e "$NEW_PATH" ] || [ -L "$NEW_PATH" ]
                then
                    echo
                    echo "An item with this name already exists."
                    echo "Rename cancelled."
                    printf "Press ENTER to continue..."
                    read
                    continue
                fi

                mv "$SELECTED_FILE" "$NEW_PATH"

                if [ $? -eq 0 ]
                then
                    echo
                    echo "File renamed successfully."
                else
                    echo
                    echo "Failed to rename file."
                fi

                printf "Press ENTER to continue..."
                read
                ;;

            0)
                return
                ;;

            *)
                echo
                echo "Invalid choice."
                printf "Press ENTER to continue..."
                read
                ;;
        esac
    done
}
directory_actions()
{
    CURRENT_DIRECTORY="$1"

    while true
    do
        clear

        echo "DIRECTORY ACTIONS"
        echo "--------------------------------"
        echo "Current directory:"
        echo "$CURRENT_DIRECTORY"
        echo "--------------------------------"
        echo
        echo "1. Create File"
        echo "2. Create Directory"
        echo "0. Back"
        echo

        printf "Select: "
        read -r DIRECTORY_ACTION

        case "$DIRECTORY_ACTION" in

            1)
                echo
                printf "Enter new file name: "
                read -r NEW_FILE

                if [ -z "$NEW_FILE" ]
                then
                    echo
                    echo "File creation cancelled."
                    printf "Press ENTER to continue..."
                    read
                    continue
                fi

                NEW_FILE_PATH="$CURRENT_DIRECTORY/$NEW_FILE"

                if [ -e "$NEW_FILE_PATH" ]
                then
                    echo
                    echo "An item with this name already exists."
                    printf "Press ENTER to continue..."
                    read
                    continue
                fi

                touch "$NEW_FILE_PATH"

                if [ $? -eq 0 ]
                then
                    echo
                    echo "File created successfully."
                else
                    echo
                    echo "Failed to create file."
                fi

                printf "Press ENTER to continue..."
                read
                ;;

            2)
                echo
                printf "Enter new directory name: "
                read -r NEW_DIRECTORY

                if [ -z "$NEW_DIRECTORY" ]
                then
                    echo
                    echo "Directory creation cancelled."
                    printf "Press ENTER to continue..."
                    read
                    continue
                fi

                NEW_DIRECTORY_PATH="$CURRENT_DIRECTORY/$NEW_DIRECTORY"

                if [ -e "$NEW_DIRECTORY_PATH" ]
                then
                    echo
                    echo "An item with this name already exists."
                    printf "Press ENTER to continue..."
                    read
                    continue
                fi

                mkdir "$NEW_DIRECTORY_PATH"

                if [ $? -eq 0 ]
                then
                    echo
                    echo "Directory created successfully."
                else
                    echo
                    echo "Failed to create directory."
                fi

                printf "Press ENTER to continue..."
                read
                ;;

            0)
                return
                ;;

            *)
                echo
                echo "Invalid choice."
                printf "Press ENTER to continue..."
                read
                ;;
        esac
    done
}
destination_browser()
{
    DESTINATION_ROOT="$1"
    DESTINATION_CURRENT="$1"

    while true
    do
        clear

        echo "DESTINATION BROWSER"
        echo "--------------------------------"
        echo "Current directory:"
        echo "$DESTINATION_CURRENT"
        echo "--------------------------------"
        echo

        ITEM_COUNT=0
        DESTINATION_LIST="$HOME/.destination_browser_list"

        : > "$DESTINATION_LIST"

        for ITEM in "$DESTINATION_CURRENT"/*
        do
            [ -e "$ITEM" ] || continue

            ITEM_COUNT=$((ITEM_COUNT + 1))

            printf "%s\n" "$ITEM" >> "$DESTINATION_LIST"

            ITEM_NAME="${ITEM##*/}"

            if [ -d "$ITEM" ]
            then
                printf "%d. [DIR]  %s\n" \
                    "$ITEM_COUNT" "$ITEM_NAME"
            else
                printf "%d. [FILE] %s\n" \
                    "$ITEM_COUNT" "$ITEM_NAME"
            fi
        done

        if [ "$ITEM_COUNT" -eq 0 ]
        then
            echo "Directory is empty."
        fi

        echo
        echo "0. Select This Directory"
        echo "B. Go Back"
        echo

        printf "Select: "
        read -r DESTINATION_CHOICE

        case "$DESTINATION_CHOICE" in

            0)
                SELECTED_DESTINATION="$DESTINATION_CURRENT"
                return 0
                ;;

            [Bb])
                if [ "$DESTINATION_CURRENT" = "$DESTINATION_ROOT" ]
                then
                    return 1
                fi

                DESTINATION_CURRENT="${DESTINATION_CURRENT%/*}"

                if [ -z "$DESTINATION_CURRENT" ]
                then
                    DESTINATION_CURRENT="/"
                fi
                ;;

            ''|*[!0-9]*)
                echo
                echo "Invalid choice."
                printf "Press ENTER to continue..."
                read
                ;;

            *)
                if [ "$DESTINATION_CHOICE" -lt 1 ] ||
                   [ "$DESTINATION_CHOICE" -gt "$ITEM_COUNT" ]
                then
                    echo
                    echo "Item number is out of range."
                    printf "Press ENTER to continue..."
                    read
                    continue
                fi

                SELECTED_DESTINATION_ITEM=$(
                    sed -n "${DESTINATION_CHOICE}p" \
                    "$DESTINATION_LIST"
                )

                if [ -d "$SELECTED_DESTINATION_ITEM" ]
                then
                    DESTINATION_CURRENT="$SELECTED_DESTINATION_ITEM"
                else
                    echo
                    echo "This is a file."
                    echo "Only directories can be selected as destinations."
                    printf "Press ENTER to continue..."
                    read
                fi
                ;;
        esac
    done
}
storage_selector()
{
    while true
    do
        clear

        echo "SELECT STORAGE"
        echo "--------------------------------"
        echo "1. Private Termux Storage"
        echo "2. Shared Internal Storage"
        echo "0. Cancel"
        echo

        printf "Select: "
        read -r STORAGE_CHOICE

        case "$STORAGE_CHOICE" in

            1)
                SELECTED_STORAGE_ROOT="$HOME"
                return 0
                ;;

            2)
                if [ ! -d "$HOME/storage/shared" ]
                then
                    echo
                    echo "Shared storage is not available."
                    echo "Run: termux-setup-storage"
                    echo
                    printf "Press ENTER to continue..."
                    read
                    continue
                fi

                SELECTED_STORAGE_ROOT="$HOME/storage/shared"
                return 0
                ;;

            0)
                return 1
                ;;

            *)
                echo
                echo "Invalid choice."
                printf "Press ENTER to continue..."
                read
                ;;
        esac
    done
}
advanced_ai_start()
{
    ADVANCED_AI_FILE="advanced_ai.py"

    if [ ! -f "$ADVANCED_AI_FILE" ]; then
        echo
        echo "AI file not found."
        printf "Press ENTER to continue..."
        read
        return 1
    fi

    if ! command -v python >/dev/null 2>&1; then
        echo
        echo "Python is required."
        printf "Press ENTER to continue..."
        read
        return 1
    fi

    python "$ADVANCED_AI_FILE"
}
load_advanced_database()
{
    ADVANCED_DATABASE_FILE="advanced_database.db"

    if [ ! -f "$ADVANCED_DATABASE_FILE" ]; then
        echo "Database file not found: $ADVANCED_DATABASE_FILE"
        return 1
    fi

    if [ ! -r "$ADVANCED_DATABASE_FILE" ]; then
        echo "Database file is not readable: $ADVANCED_DATABASE_FILE"
        return 1
    fi

    ADVANCED_COMMAND_COUNT=$(grep -c '^C|' "$ADVANCED_DATABASE_FILE" 2>/dev/null || true)
    ADVANCED_ERROR_COUNT=$(grep -c '^E|' "$ADVANCED_DATABASE_FILE" 2>/dev/null || true)
    ADVANCED_RULE_COUNT=$(grep -c '^R|' "$ADVANCED_DATABASE_FILE" 2>/dev/null || true)

    return 0
}
analyze_command_error()
{
    ADVANCED_USER_COMMAND="$1"

    if [ -z "$ADVANCED_USER_COMMAND" ]; then
        echo "No command was entered."
        return 1
    fi

    # ═══════════════════════════════════════════════   ← 🆕 ابدأ الإضافة
    # Check if this is an install command                ← 🆕
    ADVANCED_FIRST_WORD=$(printf '%s\n' "$ADVANCED_USER_COMMAND" | awk '{print $1}')   # ← 🆕
    ADVANCED_SECOND_WORD=$(printf '%s\n' "$ADVANCED_USER_COMMAND" | awk '{print $2}')  # ← 🆕

    case "$ADVANCED_FIRST_WORD" in                       # ← 🆕
        pkg|apt|apt-get|pip|pip3|npm|yarn|pnpm|gem|cargo|go)  # ← 🆕
            case "$ADVANCED_SECOND_WORD" in              # ← 🆕
                install|add|i|get)                       # ← 🆕
                    if command -v python3 >/dev/null 2>&1 && [ -f "advanced_ai.py" ]; then  # ← 🆕
                        python3 advanced_ai.py --install "$ADVANCED_USER_COMMAND"           # ← 🆕
                        return $?                            # ← 🆕
                    fi                                       # ← 🆕
                    ;;                                       # ← 🆕
            esac                                         # ← 🆕
            ;;                                           # ← 🆕
    esac                                                 # ← 🆕
    # ═══════════════════════════════════════════════   ← 🆕 نهاية الإضافة

    ADVANCED_ERROR_FILE="$TEMP_DIR/advanced_error.$$"

    ADVANCED_COMMAND_NAME=$(printf '%s\n' "$ADVANCED_USER_COMMAND" | awk '{print $1}')

    echo "Running command..."
    echo

    sh -c "$ADVANCED_USER_COMMAND" 2>"$ADVANCED_ERROR_FILE"

    ADVANCED_EXIT_CODE=$?

    if [ "$ADVANCED_EXIT_CODE" -eq 0 ]; then
        rm -f "$ADVANCED_ERROR_FILE"
        return 0
    fi

    echo
    echo "Command failed:"

    if [ -s "$ADVANCED_ERROR_FILE" ]; then
        cat "$ADVANCED_ERROR_FILE"
    else
        echo "Command failed with exit code: $ADVANCED_EXIT_CODE"
    fi

    echo
    echo "AI is analyzing the error..."
    echo

    if [ ! -f "advanced_ai.py" ]; then
        echo "AI file not found."
        rm -f "$ADVANCED_ERROR_FILE"
        return "$ADVANCED_EXIT_CODE"
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        echo "Python3 is not available."
        rm -f "$ADVANCED_ERROR_FILE"
        return "$ADVANCED_EXIT_CODE"
    fi

    python3 advanced_ai.py "$ADVANCED_USER_COMMAND"

    ADVANCED_AI_EXIT_CODE=$?

    # --------------------------------------------------------
    # EXTERNAL AI FALLBACK
    # --------------------------------------------------------
    if is_external_ai_available; then
        echo ""
        echo "------------------------------------"
        echo "Consulting External AI for more details..."
        echo "------------------------------------"

        if [ -s "$ADVANCED_ERROR_FILE" ]; then
            local err_content=$(cat "$ADVANCED_ERROR_FILE")
        else
            local err_content="Command failed with exit code: $ADVANCED_EXIT_CODE"
        fi

        external_ai_analyze_error "$ADVANCED_USER_COMMAND" "$err_content"
    fi

    rm -f "$ADVANCED_ERROR_FILE"

    return "$ADVANCED_EXIT_CODE"
}
# ============================================================
# EXTERNAL AI - API HELPERS
# ============================================================

# Default paths (relative to current working directory)
API_CONFIG_FILE="api_config.json"
API_CLIENT_FILE="api_client.py"

# ============================================================
# mask_api_key - Hide API key for display
# ============================================================
mask_api_key() {
    local key="$1"

    if [ -z "$key" ]; then
        printf "(not set)"
        return
    fi

    local length=${#key}

    if [ "$length" -le 8 ]; then
        printf "****"
        return
    fi

    local prefix=$(printf '%s' "$key" | cut -c1-3)
    local suffix=$(printf '%s' "$key" | cut -c$((length - 3))-)

    printf "%s****%s" "$prefix" "$suffix"
}

# ============================================================
# sanitize_api_error - Remove secrets from error messages
# ============================================================
sanitize_api_error() {
    local text="$1"

    if [ -z "$text" ]; then
        printf ""
        return
    fi

    # Load key to redact it
    local secret=""
    if [ -f "$API_CONFIG_FILE" ]; then
        secret=$(grep -o '"key"[[:space:]]*:[[:space:]]*"[^"]*"' "$API_CONFIG_FILE" 2>/dev/null | sed 's/.*"key"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    fi

    if [ -n "$secret" ]; then
        # Replace key with mask
        text=$(printf '%s' "$text" | sed "s|$secret|***REDACTED***|g")
    fi

    # Common secret patterns
    text=$(printf '%s' "$text" | sed 's/sk-[A-Za-z0-9_-]\{10,\}/***REDACTED***/g')
    text=$(printf '%s' "$text" | sed 's/Bearer [A-Za-z0-9_.-]\{10,\}/Bearer ***REDACTED***/g')

    printf '%s' "$text"
}

# ============================================================
# load_api_settings - Read value from config JSON
# Usage: load_api_settings "provider"
# ============================================================
load_api_settings() {
    local field="$1"

    if [ ! -f "$API_CONFIG_FILE" ]; then
        return 1
    fi

    local value=""

    case "$field" in
        provider)
            value=$(grep -o '"provider"[[:space:]]*:[[:space:]]*"[^"]*"' "$API_CONFIG_FILE" 2>/dev/null | sed 's/.*"provider"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
            ;;
        url)
            value=$(grep -o '"url"[[:space:]]*:[[:space:]]*"[^"]*"' "$API_CONFIG_FILE" 2>/dev/null | sed 's/.*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
            ;;
        model)
            value=$(grep -o '"model"[[:space:]]*:[[:space:]]*"[^"]*"' "$API_CONFIG_FILE" 2>/dev/null | sed 's/.*"model"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
            ;;
        key)
            value=$(grep -o '"key"[[:space:]]*:[[:space:]]*"[^"]*"' "$API_CONFIG_FILE" 2>/dev/null | sed 's/.*"key"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
            ;;
        max_tokens)
            value=$(grep -o '"max_tokens"[[:space:]]*:[[:space:]]*[0-9]*' "$API_CONFIG_FILE" 2>/dev/null | sed 's/.*:[[:space:]]*//')
            ;;
        timeout)
            value=$(grep -o '"timeout"[[:space:]]*:[[:space:]]*[0-9]*' "$API_CONFIG_FILE" 2>/dev/null | sed 's/.*:[[:space:]]*//')
            ;;
        temperature)
            value=$(grep -o '"temperature"[[:space:]]*:[[:space:]]*[0-9.]*' "$API_CONFIG_FILE" 2>/dev/null | sed 's/.*:[[:space:]]*//')
            ;;
        enabled)
            value=$(grep -o '"enabled"[[:space:]]*:[[:space:]]*[a-z]*' "$API_CONFIG_FILE" 2>/dev/null | sed 's/.*:[[:space:]]*//')
            ;;
        *)
            return 1
            ;;
    esac

    printf '%s' "$value"
    return 0
}

# ============================================================
# save_api_settings - Write value into config JSON
# Usage: save_api_settings "key" "value"
# ============================================================
save_api_settings() {
    local field="$1"
    local value="$2"

    if [ ! -f "$API_CONFIG_FILE" ]; then
        return 1
    fi

    # Escape special sed characters in value
    local escaped_value=$(printf '%s' "$value" | sed 's/[\/&]/\\&/g')
    local escaped_field=$(printf '%s' "$field" | sed 's/[\/&]/\\&/g')

    # Handle different value types
    case "$field" in
        max_tokens|timeout)
            sed -i "s|\"$escaped_field\"[[:space:]]*:[[:space:]]*[0-9]*|\"$escaped_field\": $escaped_value|" "$API_CONFIG_FILE"
            ;;
        temperature)
            sed -i "s|\"$escaped_field\"[[:space:]]*:[[:space:]]*[0-9.]*|\"$escaped_field\": $escaped_value|" "$API_CONFIG_FILE"
            ;;
        enabled)
            sed -i "s|\"$escaped_field\"[[:space:]]*:[[:space:]]*[a-z]*|\"$escaped_field\": $escaped_value|" "$API_CONFIG_FILE"
            ;;
        *)
            sed -i "s|\"$escaped_field\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"$escaped_field\": \"$escaped_value\"|" "$API_CONFIG_FILE"
            ;;
    esac

    chmod 600 "$API_CONFIG_FILE" 2>/dev/null
    return 0
}

# ============================================================
# remove_api_key - Clear the API key from config
# ============================================================
remove_api_key() {
    if [ ! -f "$API_CONFIG_FILE" ]; then
        print_error "Config file not found."
        return 1
    fi

    save_api_settings "key" ""
    save_api_settings "enabled" "false"

    print_ok "API Key removed."
    return 0
}

# ============================================================
# is_external_ai_available - Check if API is ready
# ============================================================
is_external_ai_available() {
    if [ ! -f "$API_CONFIG_FILE" ]; then
        return 1
    fi

    if [ ! -f "$API_CLIENT_FILE" ]; then
        return 1
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        return 1
    fi

    local key=$(load_api_settings "key")
    local url=$(load_api_settings "url")
    local model=$(load_api_settings "model")
    local enabled=$(load_api_settings "enabled")

    if [ "$enabled" != "true" ]; then
        return 1
    fi

    if [ -z "$key" ] || [ -z "$url" ] || [ -z "$model" ]; then
        return 1
    fi

    return 0
}

# ============================================================
# call_external_ai - Send messages to API
# Usage: call_external_ai "json_messages_array"
# Returns: 0 on success (response in EXTERNAL_AI_RESPONSE)
#          1 on failure (error in EXTERNAL_AI_ERROR)
# ============================================================
call_external_ai() {
    local messages_json="$1"

    EXTERNAL_AI_RESPONSE=""
    EXTERNAL_AI_ERROR=""

    if ! is_external_ai_available; then
        EXTERNAL_AI_ERROR="External AI not available (missing key or disabled)"
        return 1
    fi

    if [ -z "$messages_json" ]; then
        EXTERNAL_AI_ERROR="No messages provided"
        return 1
    fi

    local api_url=$(load_api_settings "url")
    local api_key=$(load_api_settings "key")
    local api_model=$(load_api_settings "model")
    local api_max_tokens=$(load_api_settings "max_tokens")
    local api_timeout=$(load_api_settings "timeout")
    local api_temperature=$(load_api_settings "temperature")

    # Fallback defaults
    [ -z "$api_max_tokens" ] && api_max_tokens=8192
    [ -z "$api_timeout" ] && api_timeout=300
    [ -z "$api_temperature" ] && api_temperature=0.3

    # Build request JSON using python to safely escape
    local request_json=$(python3 -c "
import json, sys
messages = json.loads(sys.argv[1])
payload = {
    'url': sys.argv[2],
    'key': sys.argv[3],
    'model': sys.argv[4],
    'messages': messages,
    'max_tokens': int(sys.argv[5]),
    'timeout': int(sys.argv[6]),
    'temperature': float(sys.argv[7]),
}
print(json.dumps(payload))
" "$messages_json" "$api_url" "$api_key" "$api_model" "$api_max_tokens" "$api_timeout" "$api_temperature" 2>/dev/null)

    if [ -z "$request_json" ]; then
        EXTERNAL_AI_ERROR="Failed to build request JSON"
        return 1
    fi
# Call the client with thinking counter
local client_output=""
local client_exit=0
local tmp_output="$TEMP_DIR/api_response.$$"

printf '%s' "$request_json" | python3 "$API_CLIENT_FILE" > "$tmp_output" 2>&1 &
local client_pid=$!

local seconds=1

printf "\n"

while kill -0 "$client_pid" 2>/dev/null; do
    printf "\r\033[K  Thinking... (%d)" "$seconds"
    sleep 1
    seconds=$((seconds + 1))
done

wait "$client_pid"
client_exit=$?

printf "\r\033[K"

client_output=$(cat "$tmp_output")
rm -f "$tmp_output"

    if [ "$client_exit" -ne 0 ]; then
        EXTERNAL_AI_ERROR=$(sanitize_api_error "$client_output")
        return 1
    fi

    # Parse response (format: first line status, rest content)
    local status=$(printf '%s' "$client_output" | head -n 1)
    local content=$(printf '%s' "$client_output" | tail -n +2)

    case "$status" in
        OK)
            EXTERNAL_AI_RESPONSE="$content"
            return 0
            ;;
        HTTP_401)
            EXTERNAL_AI_ERROR="Invalid API Key (401 Unauthorized)"
            ;;
        HTTP_403)
            EXTERNAL_AI_ERROR="Access forbidden (403)"
            ;;
        HTTP_404)
            EXTERNAL_AI_ERROR="API endpoint or model not found (404)"
            ;;
        HTTP_429)
            EXTERNAL_AI_ERROR="Rate limit exceeded (429). Try again later."
            ;;
        HTTP_500|HTTP_502|HTTP_503)
            EXTERNAL_AI_ERROR="API server error ($status). Try again later."
            ;;
        NETWORK_ERROR)
            EXTERNAL_AI_ERROR="Network error: $content"
            ;;
        TIMEOUT)
            EXTERNAL_AI_ERROR="Request timed out"
            ;;
        CONFIG_ERROR)
            EXTERNAL_AI_ERROR="Configuration error: $content"
            ;;
        *)
            EXTERNAL_AI_ERROR=$(sanitize_api_error "$status: $content")
            ;;
    esac

    return 1
}

# ============================================================
# test_api_connection - Send a tiny test message
# ============================================================
test_api_connection() {
    print_info "Testing API connection..."
    echo ""

    if [ ! -f "$API_CONFIG_FILE" ]; then
        print_error "Config file not found: $API_CONFIG_FILE"
        return 1
    fi

    if [ ! -f "$API_CLIENT_FILE" ]; then
        print_error "Client file not found: $API_CLIENT_FILE"
        return 1
    fi

    local key=$(load_api_settings "key")
    local url=$(load_api_settings "url")
    local model=$(load_api_settings "model")

    if [ -z "$key" ]; then
        print_error "No API Key configured."
        return 1
    fi

    if [ -z "$url" ]; then
        print_error "No API URL configured."
        return 1
    fi

    if [ -z "$model" ]; then
        print_error "No model configured."
        return 1
    fi

    printf "  Provider : %s\n" "$(load_api_settings 'provider')"
    printf "  Model    : %s\n" "$model"
    printf "  URL      : %s\n" "$url"
    printf "  Key      : %s\n" "$(mask_api_key "$key")"
    echo ""
    echo "Sending test request..."
    echo ""

    local test_messages='[{"role":"user","content":"Reply with exactly: OK"}]'

    if call_external_ai "$test_messages"; then
        print_ok "Connected successfully."
        echo ""
        echo "Response:"
        printf "%s\n" "$EXTERNAL_AI_RESPONSE" | head -n 5
        return 0
    else
        print_error "Connection failed."
        echo ""
        printf "Reason: %s\n" "$EXTERNAL_AI_ERROR"
        return 1
    fi
}

# ============================================================
# external_ai_chat - Interactive chat with the model
# ============================================================
external_ai_chat() {
    if ! is_external_ai_available; then
        print_error "External AI is not available."
        echo ""
        echo "Please configure your API key first:"
        echo "  Advanced Mode → API Key → Add API Key"
        pause_screen
        return 1
    fi

    clear_screen

    printf "\n====================================\n"
    printf "        EXTERNAL AI CHAT\n"
    printf "====================================\n\n"
    printf "Type 'exit' to return.\n\n"

    # History (in-memory only)
    local history="[]"

    while true
    do
        printf "You: "
        IFS= read -r user_msg

        case "$user_msg" in
            exit|EXIT|quit|QUIT)
                echo ""
                print_info "Returning to menu."
                pause_screen
                return 0
                ;;

            "")
                continue
                ;;
        esac

        # Append user message to history
        history=$(python3 -c "
import json, sys
h = json.loads(sys.argv[1])
h.append({'role': 'user', 'content': sys.argv[2]})
print(json.dumps(h))
" "$history" "$user_msg" 2>/dev/null)

        printf "\nAI: "
        echo ""

        if call_external_ai "$history"; then
            printf "%s\n" "$EXTERNAL_AI_RESPONSE"

            # Append assistant response to history
            history=$(python3 -c "
import json, sys
h = json.loads(sys.argv[1])
h.append({'role': 'assistant', 'content': sys.argv[2]})
# Keep only last 10 messages to limit context
if len(h) > 30:
    h = h[-30:]
print(json.dumps(h))
" "$history" "$EXTERNAL_AI_RESPONSE" 2>/dev/null)
        else
            print_error "$EXTERNAL_AI_ERROR"
        fi

        echo ""
    done
}

# ============================================================
# external_ai_analyze_error - Send error to external AI
# Usage: external_ai_analyze_error "command" "error_text"
# ============================================================
external_ai_analyze_error() {
    local command="$1"
    local error_text="$2"

    if ! is_external_ai_available; then
        return 1
    fi

    echo ""
    print_info "Asking External AI for help..."
    echo ""

    # Build a safe prompt (no secrets)
    local system_prompt='You are a technical assistant inside Termux AI. Analyze the given command error and provide a fix. Be concise. Do not invent information. If uncertain, say so. Reply in this exact format:

CAUSE: <brief cause>
FIX: <corrected command if applicable>
EXPLANATION: <one line>'

    local user_content="Command: $command
Error:
$error_text"

    # Build messages via python to escape properly
    local messages_json=$(python3 -c "
import json, sys
msgs = [
    {'role': 'system', 'content': sys.argv[1]},
    {'role': 'user', 'content': sys.argv[2]},
]
print(json.dumps(msgs))
" "$system_prompt" "$user_content" 2>/dev/null)

    if [ -z "$messages_json" ]; then
        print_error "Failed to build request"
        return 1
    fi

    if call_external_ai "$messages_json"; then
        echo "================================================"
        echo "  External AI Analysis"
        echo "================================================"
        echo ""
        printf "%s\n" "$EXTERNAL_AI_RESPONSE"
        echo ""
        echo "================================================"
        return 0
    else
        print_error "External AI failed: $EXTERNAL_AI_ERROR"
        return 1
    fi
}
# ============================================================
# API KEY MENU
# ============================================================

api_key_menu() {
    while true
    do
        clear_screen

        local current_key=$(load_api_settings "key")
        local current_model=$(load_api_settings "model")
        local current_url=$(load_api_settings "url")
        local current_provider=$(load_api_settings "provider")
        local current_enabled=$(load_api_settings "enabled")

        printf "\n====================================\n"
        printf "            API KEY\n"
        printf "====================================\n\n"

        printf "Status:\n"
        printf "  Provider : %s\n" "${current_provider:-not set}"
        printf "  Model    : %s\n" "${current_model:-not set}"
        printf "  URL      : %s\n" "${current_url:-not set}"
        printf "  Key      : %s\n" "$(mask_api_key "$current_key")"
        printf "  Enabled  : %s\n" "${current_enabled:-false}"
        echo ""
        printf "------------------------------------\n"
        printf "1. Add API Key\n"
        printf "2. Select Provider & Model\n"
        printf "3. Test Connection\n"
        printf "4. Chat with Model\n"
        printf "5. Remove API Key\n"
        printf "6. Show Full Settings\n"
        printf "0. Back\n\n"

        printf "Select: "
        read -r API_CHOICE

        case "$API_CHOICE" in
            1)
                api_add_key
                ;;

            2)
                api_select_provider
                ;;

            3)
                clear_screen
                test_api_connection
                pause_screen
                ;;

            4)
                external_ai_chat
                ;;

            5)
                clear_screen
                printf "\nRemove API Key?\n\n"
                printf "Press ENTER to confirm, or type anything to cancel: "
                read -r confirm
                if [ -z "$confirm" ]; then
                    remove_api_key
                else
                    print_info "Cancelled."
                fi
                pause_screen
                ;;

            6)
                api_show_full_settings
                ;;

            0)
                return
                ;;

            *)
                print_error "Invalid choice."
                pause_screen
                ;;
        esac
    done
}

# ============================================================
# api_add_key - Prompt for key and save
# ============================================================
api_add_key() {
    clear_screen

    printf "\n====================================\n"
    printf "          ADD API KEY\n"
    printf "====================================\n\n"

    printf "Enter your API Key.\n"
    printf "It will be hidden while typing.\n\n"

    printf "API Key: "
    stty -echo 2>/dev/null
    IFS= read -r new_key
    stty echo 2>/dev/null
    echo ""

    if [ -z "$new_key" ]; then
        print_error "API Key cannot be empty."
        pause_screen
        return 1
    fi

    save_api_settings "key" "$new_key"
    save_api_settings "enabled" "true"

    echo ""
    print_ok "API Key saved."
    printf "Key: %s\n" "$(mask_api_key "$new_key")"
    echo ""
    print_info "Run 'Test Connection' to verify."

    pause_screen
    return 0
}

# ============================================================
# api_select_provider - Choose provider and model
# ============================================================
api_select_provider() {
    clear_screen

    printf "\n====================================\n"
    printf "     SELECT PROVIDER & MODEL\n"
    printf "====================================\n\n"

    printf "1. OpenAI          (gpt-4o-mini)\n"
    printf "2. OpenRouter      (qwen/qwen3.6-plus)\n"
    printf "3. Groq            (llama-3.3-70b-versatile)\n"
    printf "4. Together AI     (llama-3.1-8b-instruct-turbo)\n"
    printf "5. DeepInfra       (meta-llama/Meta-Llama-3.1-8B-Instruct)\n"
    printf "6. Mistral         (mistral-small-latest)\n"
    printf "7. Cohere          (command-r-plus)\n"
    printf "8. Cerebras        (gpt-oss-120b)\n"
    printf "9. Hugging Face    (meta-llama/Llama-3.2-3B-Instruct)\n"
    printf "10. Google Gemini   (gemini-3.8-flash)  [FREE]\n"
    printf "11. DeepSeek        (deepseek-flash)  [FREE]\n"
    printf "12. xAI Grok        (grok-4.1-fast)\n"
    printf "13. OpenAI ChatGPT  (gpt-5.5)\n"
    printf "14. Anthropic Claude (claude-sonnet-4.6)\n"
    printf "15. Perplexity      (sonar-pro)\n"
    printf "C. Custom provider\n"
    printf "0. Back\n\n"

    printf "Select: "
    read -r provider_choice

    case "$provider_choice" in
        1)
            save_api_settings "provider" "openai"
            save_api_settings "url" "https://api.openai.com/v1"
            save_api_settings "model" "gpt-4o-mini"
            print_ok "OpenAI configured."
            pause_screen
            ;;

        2)
            save_api_settings "provider" "openrouter"
            save_api_settings "url" "https://openrouter.ai/api/v1"
            save_api_settings "model" "qwen/qwen3.6-plus"
            print_ok "OpenRouter configured."
            pause_screen
            ;;

        3)
            save_api_settings "provider" "groq"
            save_api_settings "url" "https://api.groq.com/openai/v1"
            save_api_settings "model" "llama-3.3-70b-versatile"
            print_ok "Groq configured."
            pause_screen
            ;;

        4)
            save_api_settings "provider" "together"
            save_api_settings "url" "https://api.together.xyz/v1"
            save_api_settings "model" "meta-llama/Meta-Llama-3.1-8B-Instruct-Turbo"
            print_ok "Together AI configured."
            pause_screen
            ;;

        5)
            save_api_settings "provider" "deepinfra"
            save_api_settings "url" "https://api.deepinfra.com/v1/openai/"
            save_api_settings "model" "meta-llama/Meta-Llama-3.1-8B-Instruct"
            print_ok "DeepInfra configured."
            pause_screen
            ;;

        6)
            save_api_settings "provider" "mistral"
            save_api_settings "url" "https://api.mistral.ai/v1"
            save_api_settings "model" "mistral-small-latest"
            print_ok "Mistral configured."
            pause_screen
            ;;

        7)
            save_api_settings "provider" "cohere"
            save_api_settings "url" "https://api.cohere.ai/compatibility/v1"
            save_api_settings "model" "command-r-plus"
            print_ok "Cohere configured."
            pause_screen
            ;;

        8)
            save_api_settings "provider" "cerebras"
            save_api_settings "url" "https://api.cerebras.ai/v1"
            save_api_settings "model" "gpt-oss-120b"
            print_ok "Cerebras configured."
            pause_screen
            ;;

        9)
            save_api_settings "provider" "huggingface"
            save_api_settings "url" "https://api-inference.huggingface.co/v1"
            save_api_settings "model" "meta-llama/Llama-3.2-3B-Instruct"
            print_ok "Hugging Face configured."
            pause_screen
            ;;


10)
    save_api_settings "provider" "google"
    save_api_settings "url" "https://generativelanguage.googleapis.com/v1beta/openai/"
    save_api_settings "model" "gemini-3.8-flash"
    print_ok "Google Gemini configured."
    pause_screen
    ;;

11)
    save_api_settings "provider" "deepseek"
    save_api_settings "url" "https://api.deepseek.com/v1"
    save_api_settings "model" "deepseek-flash"
    print_ok "DeepSeek configured."
    pause_screen
    ;;

12)
    save_api_settings "provider" "xai"
    save_api_settings "url" "https://api.x.ai/v1"
    save_api_settings "model" "grok-4.1-fast"
    print_ok "xAI Grok configured."
    pause_screen
    ;;

13)
    save_api_settings "provider" "openai"
    save_api_settings "url" "https://api.openai.com/v1"
    save_api_settings "model" "gpt-5.5"
    print_ok "OpenAI ChatGPT configured."
    pause_screen
    ;;

14)
    save_api_settings "provider" "anthropic"
    save_api_settings "url" "https://api.anthropic.com/v1"
    save_api_settings "model" "claude-sonnet-4.6"
    print_ok "Anthropic Claude configured."
    pause_screen
    ;;

15)
    save_api_settings "provider" "perplexity"
    save_api_settings "url" "https://api.perplexity.ai"
    save_api_settings "model" "sonar-pro"
    print_ok "Perplexity configured."
    pause_screen
    ;;

        [Cc])
            printf "\nAPI URL: "
            IFS= read -r custom_url
            if [ -z "$custom_url" ]; then
                print_error "URL cannot be empty."
                pause_screen
                return 1
            fi

            printf "Model name: "
            IFS= read -r custom_model
            if [ -z "$custom_model" ]; then
                print_error "Model cannot be empty."
                pause_screen
                return 1
            fi

            save_api_settings "provider" "custom"
            save_api_settings "url" "$custom_url"
            save_api_settings "model" "$custom_model"
            print_ok "Custom provider configured."
            pause_screen
            ;;

        0)
            return
            ;;

        *)
            print_error "Invalid choice."
            pause_screen
            ;;
    esac
}

# ============================================================
# api_show_full_settings - Display settings (key masked)
# ============================================================
api_show_full_settings() {
    clear_screen

    printf "\n====================================\n"
    printf "        API SETTINGS\n"
    printf "====================================\n\n"

    printf "  Provider    : %s\n" "$(load_api_settings 'provider')"
    printf "  URL         : %s\n" "$(load_api_settings 'url')"
    printf "  Model       : %s\n" "$(load_api_settings 'model')"
    printf "  API Key     : %s\n" "$(mask_api_key "$(load_api_settings 'key')")"
    printf "  Max Tokens  : %s\n" "$(load_api_settings 'max_tokens')"
    printf "  Timeout     : %s seconds\n" "$(load_api_settings 'timeout')"
    printf "  Temperature : %s\n" "$(load_api_settings 'temperature')"
    printf "  Enabled     : %s\n" "$(load_api_settings 'enabled')"
    echo ""
    printf "  Config File : %s\n" "$API_CONFIG_FILE"
    printf "  Client File : %s\n" "$API_CLIENT_FILE"
    echo ""

    pause_screen
}

advanced_mode()
{
    clear

    advanced_ai_start

    if [ "$?" -ne 0 ]; then
        return
    fi

    echo
    echo "================================"
    echo "        ADVANCED MODE"
    echo "================================"
    echo
    echo "1. Command Analyzer"
    echo "2. Discover Commands"
    echo "3. Auto-Learn Command"
    echo "4. API Key"
    echo "0. Back"
    echo

    printf "Select: "
    read -r ADVANCED_CHOICE

    case "$ADVANCED_CHOICE" in

        1)
            clear

            echo "COMMAND ANALYZER"
            echo "================================"
            echo
            echo "Type a command."
            echo "Type exit to return."
            echo

            while true
            do
                printf "> "
                IFS= read -r ADVANCED_USER_COMMAND

                case "$ADVANCED_USER_COMMAND" in

                    exit)
                        break
                        ;;

                    "")
                        continue
                        ;;

                    *)
                        echo
                        analyze_command_error "$ADVANCED_USER_COMMAND"
                        echo
                        ;;
                esac
            done
            ;;

2)
    clear

    echo "DISCOVER COMMANDS"
    echo "================================"
    echo
    echo "Scanning installed commands..."
    echo

    if ! command -v python3 >/dev/null 2>&1; then
        echo "Python3 is required."
        printf "Press ENTER to continue..."
        read
        return 1
    fi

    if [ ! -f "advanced_ai.py" ]; then
        echo "AI file not found."
        printf "Press ENTER to continue..."
        read
        return 1
    fi

    python3 advanced_ai.py --discover

    echo
    printf "Press ENTER to continue..."
    read
    ;;

3)
    while true
    do
        clear

        echo "AUTO-LEARN COMMAND"
        echo "================================"
        echo

        printf "Command name (or 0 to go back): "
        read -r LEARN_COMMAND

        case "$LEARN_COMMAND" in

            0|"")
                break
                ;;

            *)
                python3 advanced_ai.py --learn "$LEARN_COMMAND"
                echo
                printf "Press ENTER to continue..."
                read
                ;;
        esac
    done
    ;;
        4)
            api_key_menu
            ;;

        0)
            return
            ;;

        *)
            echo
            echo "Invalid choice."
            printf "Press ENTER to continue..."
            read
            ;;
    esac

}
browser_mode()
{
    WEB_ENGINE_FILE="web_engine.py"

    if [ ! -f "$WEB_ENGINE_FILE" ]; then
        echo ""
        print_error "web_engine.py not found."
        echo "Attempting to recreate..."
        echo ""
        bootstrap_files
    fi

    if [ ! -f "$WEB_ENGINE_FILE" ]; then
        print_error "Could not create web_engine.py."
        pause_screen
        return 1
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        print_error "Python3 is required."
        pause_screen
        return 1
    fi

    python3 "$WEB_ENGINE_FILE"
    return 0
}
p2p_mode()
{
    P2P_FILE="p2p_chat.py"

    if [ ! -f "$P2P_FILE" ]; then
        echo ""
        print_error "p2p_chat.py not found."
        echo "Attempting to recreate..."
        echo ""
        bootstrap_files
    fi

    if [ ! -f "$P2P_FILE" ]; then
        print_error "Could not create p2p_chat.py."
        pause_screen
        return 1
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        print_error "Python3 is required."
        pause_screen
        return 1
    fi

    # تحقق من paho-mqtt
    if ! python3 -c "import paho.mqtt.client" 2>/dev/null; then
        echo ""
        print_error "paho-mqtt is not installed."
        echo ""
        echo "Install it with:"
        echo "  pip install paho-mqtt"
        echo ""
        printf "Do you want to install it now? (y/N): "
        read INSTALL_MQTT

        case "$INSTALL_MQTT" in
            y|Y)
                echo ""
                print_info "Installing paho-mqtt..."
                pip install paho-mqtt
                if [ $? -ne 0 ]; then
                    print_error "Installation failed."
                    pause_screen
                    return 1
                fi
                print_ok "Installed successfully."
                echo ""
                ;;
            *)
                print_info "Cancelled."
                pause_screen
                return 1
                ;;
        esac
    fi

    python3 "$P2P_FILE"
    return 0
}
readme_mode()
{
    README_FILE="README.md"

    if [ ! -f "$README_FILE" ]; then
        print_error "README.md not found."
        bootstrap_files
    fi

    if [ ! -f "$README_FILE" ]; then
        print_error "Could not create README.md."
        pause_screen
        return 1
    fi

    TOTAL_LINES=$(wc -l < "$README_FILE")
    CHUNK=30
    START=1

    while [ "$START" -le "$TOTAL_LINES" ]
    do
        clear_screen

        END=$((START + CHUNK - 1))

        sed -n "${START},${END}p" "$README_FILE"

        printf "\n"
        printf "====================================\n"
        printf "  Lines %d-%d of %d\n" "$START" "$END" "$TOTAL_LINES"
        printf "====================================\n"

        if [ "$END" -ge "$TOTAL_LINES" ]; then
            break
        fi

        printf "\nPress ENTER for next page..."
        read dummy

        START=$((START + CHUNK))
    done

    pause_screen
    return 0
}
main_menu() {
    while true
    do
        show_header

        printf "MAIN MENU\n"
        printf '%s\n\n'  "---------\n\n"

        printf "1. Normal Mode\n"
        printf "2. Advanced Mode\n"
        printf "3. Browser\n"
        printf "4. P2P Chat\n"
        printf "5. README\n"
        printf "0. Exit\n\n"

        printf "Select: "
        read main_choice

        case "$main_choice" in
            1)
                normal_mode
                ;;

            2)
                advanced_mode
                ;;

            3)
                browser_mode
                ;;
            4)
                p2p_mode
                ;;
            5)
                readme_mode
                ;;

            0)
                clear_screen
                printf "\nGoodbye!\n"
                exit 0
                ;;

            *)
                print_error "Invalid choice."
                pause_screen
                ;;
        esac
    done
}
bootstrap_files
main_menu
