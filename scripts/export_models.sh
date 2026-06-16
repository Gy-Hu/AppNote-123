#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

symbiotic_root="${SYMBIOTIC_ROOT:-/Users/huguangyu/orb_env/tabbycad/symbiotic-20201006A-academic-licenses}"
symbiotic_license="${SYMBIOTIC_LICENSE:-/Users/huguangyu/orb_env/tabbycad/symbiotic.lic}"
sby_bin="${SBY_BIN:-/Users/huguangyu/coding_env/oss-cad-suite/bin/sby}"
yosys_bin="${YOSYS_BIN:-$symbiotic_root/bin/yosys}"
export_yosys_bin="${EXPORT_YOSYS_BIN:-/Users/huguangyu/coding_env/oss-cad-suite/bin/yosys}"
orb_machine="${ORB_MACHINE:-ubuntu-amd64-22}"
tabby_yosys_mode="${TABBY_YOSYS_MODE:-auto}"
export_yosys_mode="${EXPORT_YOSYS_MODE:-native}"

export SYMBIOTIC_LICENSE="$symbiotic_license"

default_targets=(
  "veer:bmc"
  "veer:axi_bmc"
  "cv32e40x:bmc"
  "pspin:riscv_core"
  "pspin:core_region"
  "pspin:pulp_cluster"
)

if (($#)); then
  targets=("$@")
else
  targets=("${default_targets[@]}")
fi

models_dir="$repo_root/exports/models"
work_root="$repo_root/exports/work"
mkdir -p "$models_dir" "$work_root"

detect_tabby_yosys_mode() {
  case "$tabby_yosys_mode" in
    native|orb) echo "$tabby_yosys_mode" ;;
    auto)
      if "$yosys_bin" -V >/dev/null 2>&1; then
        echo native
      elif command -v orb >/dev/null 2>&1; then
        echo orb
      else
        echo "Tabby Yosys is not executable natively and orb is not available" >&2
        return 1
      fi
      ;;
    *)
      echo "invalid TABBY_YOSYS_MODE='$tabby_yosys_mode' (expected auto, native, or orb)" >&2
      return 1
      ;;
  esac
}

tabby_yosys_mode="$(detect_tabby_yosys_mode)"

run_tabby_yosys() {
  if [[ "$tabby_yosys_mode" == "native" ]]; then
    env \
      SYMBIOTIC_LICENSE="$symbiotic_license" \
      PATH="$symbiotic_root/bin:$PATH" \
      "$yosys_bin" "$@"
  else
    orb -m "$orb_machine" env \
      SYMBIOTIC_LICENSE="$symbiotic_license" \
      PATH="$symbiotic_root/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
      "$yosys_bin" "$@"
  fi
}

run_export_yosys() {
  case "$export_yosys_mode" in
    native)
      "$export_yosys_bin" "$@"
      ;;
    tabby)
      run_tabby_yosys "$@"
      ;;
    *)
      echo "invalid EXPORT_YOSYS_MODE='$export_yosys_mode' (expected native or tabby)" >&2
      return 1
      ;;
  esac
}

setup_cv32e40x_env() {
  local base="$repo_root/cv32e40x/core-v-verif"
  export CORE_V_VERIF="${CORE_V_VERIF:-$base}"
  export CV_CORE="${CV_CORE:-cv32e40x}"
  export CV_CORE_PKG="${CV_CORE_PKG:-$CORE_V_VERIF/core-v-cores/$CV_CORE}"
  export DV_ISA_DECODER_PATH="${DV_ISA_DECODER_PATH:-$CORE_V_VERIF/lib/isa_decoder}"
  export DV_SUPPORT_PATH="${DV_SUPPORT_PATH:-$CORE_V_VERIF/lib/support}"
  export DV_UVM_TESTCASE_PATH="${DV_UVM_TESTCASE_PATH:-$CORE_V_VERIF/$CV_CORE/tests/uvmt}"
  export DV_UVMA_PATH="${DV_UVMA_PATH:-$CORE_V_VERIF/lib/uvm_agents}"
  export DV_UVME_PATH="${DV_UVME_PATH:-$CORE_V_VERIF/$CV_CORE/env/uvme}"
  export DV_UVMT_PATH="${DV_UVMT_PATH:-$CORE_V_VERIF/$CV_CORE/tb/uvmt}"
  export DESIGN_RTL_DIR="${DESIGN_RTL_DIR:-$CV_CORE_PKG/rtl}"
}

sby_file_for() {
  case "$1" in
    veer) echo "veer.sby" ;;
    cv32e40x) echo "cv32e40x.sby" ;;
    pspin) echo "pspin_test.sby" ;;
    *) echo "unknown design '$1'" >&2; return 1 ;;
  esac
}

model_name_for() {
  case "$1" in
    veer:bmc) echo "veer" ;;
    veer:axi_bmc) echo "veer_axi" ;;
    cv32e40x:bmc) echo "cv32e40x" ;;
    *)
      local design="${1%%:*}"
      local task="${1#*:}"
      echo "${design}_${task//-/_}"
      ;;
  esac
}

extract_script() {
  local config="$1"
  local output="$2"
  awk '
    /^\[script\]$/ { in_script = 1; next }
    /^\[/ { if (in_script) exit }
    in_script { print }
  ' "$config" > "$output"
}

rewrite_frontend_commands() {
  local script="$1"
  local design="$2"
  python3 - "$script" "$design" <<'PY'
import os
import re
import shlex
import sys
from pathlib import Path

script_path = Path(sys.argv[1])
design = sys.argv[2]

def expand_vars(text):
    text = re.sub(r"\$\(([^)]+)\)", lambda m: os.environ.get(m.group(1), m.group(0)), text)
    return os.path.expandvars(text)

def yq(text):
    text = str(text)
    if re.fullmatch(r"[A-Za-z0-9_./${}\[\]+:=,-]+", text):
        return text
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'

def resolve_path(token, base):
    token = expand_vars(token)
    path = Path(token)
    if not path.is_absolute():
        path = base / path
    return str(path)

def parse_flist(path, seen=None):
    if seen is None:
        seen = set()
    path = Path(expand_vars(str(path)))
    if not path.is_absolute():
        path = (Path.cwd() / path).resolve()
    if path in seen:
        return [], [], []
    seen.add(path)
    base = path.parent
    incdirs = []
    defines = []
    files = []

    with path.open() as f:
        for raw_line in f:
            line = raw_line.strip()
            if not line or line.startswith("#") or line.startswith("//"):
                continue
            if "#" in line:
                line = line.split("#", 1)[0].strip()
            if "//" in line:
                line = line.split("//", 1)[0].strip()
            if not line:
                continue

            try:
                tokens = shlex.split(line)
            except ValueError:
                tokens = line.split()

            i = 0
            while i < len(tokens):
                token = expand_vars(tokens[i])
                if not token:
                    i += 1
                    continue

                if token == "-f":
                    i += 1
                    if i >= len(tokens):
                        raise SystemExit(f"missing file after -f in {path}")
                    nested = resolve_path(tokens[i], base)
                    n_incdirs, n_defines, n_files = parse_flist(nested, seen)
                    incdirs.extend(n_incdirs)
                    defines.extend(n_defines)
                    files.extend(n_files)
                elif token.startswith("-f") and len(token) > 2:
                    nested = resolve_path(token[2:], base)
                    n_incdirs, n_defines, n_files = parse_flist(nested, seen)
                    incdirs.extend(n_incdirs)
                    defines.extend(n_defines)
                    files.extend(n_files)
                elif token.startswith("+incdir+"):
                    for incdir in token[len("+incdir+"):].split("+"):
                        if incdir:
                            incdirs.append(resolve_path(incdir, base))
                elif token.startswith("+define+"):
                    for define in token[len("+define+"):].split("+"):
                        if define:
                            defines.append(define)
                elif token.startswith("-"):
                    pass
                else:
                    files.append(resolve_path(token, base))
                i += 1

    return incdirs, defines, files

def unique(seq):
    out = []
    seen = set()
    for item in seq:
        if item not in seen:
            seen.add(item)
            out.append(item)
    return out

def emit_flist(flist, original_line):
    incdirs, defines, files = parse_flist(flist)
    incdirs = unique(incdirs)
    defines = unique(defines)
    lines = [f"# expanded for Tabby Yosys 2020: {original_line.rstrip()}"]
    for start in range(0, len(incdirs), 32):
        lines.append("verific -vlog-incdir " + " ".join(yq(x) for x in incdirs[start:start + 32]))
    for start in range(0, len(defines), 32):
        lines.append("verific -vlog-define " + " ".join(yq(x) for x in defines[start:start + 32]))
    if files:
        lines.append("verific -formal " + " ".join(yq(x) for x in files))
    if design == "veer" and re.match(r"\s*read\s+-f\s+-formal\s+veer\.f\s*$", original_line):
        lines.append("verific -import -extnets veer_wrapper")
    return lines

new_lines = []
for line in script_path.read_text().splitlines():
    stripped = line.strip()
    try:
        tokens = shlex.split(stripped)
    except ValueError:
        tokens = []

    if len(tokens) == 4 and tokens[:3] == ["read", "-f", "-formal"]:
        new_lines.extend(emit_flist(tokens[3], line))
        continue

    if tokens and tokens[0] == "verific" and "-f" in tokens and "-formal" in tokens:
        candidates = [tok for tok in tokens[1:] if not tok.startswith("-")]
        if not candidates:
            raise SystemExit(f"could not find flist in line: {line}")
        new_lines.extend(emit_flist(candidates[-1], line))
        continue

    new_lines.append(line)

script_path.write_text("\n".join(new_lines) + "\n")
PY
}

patch_pspin_pulp_cluster_worktree() {
  local work_dir="$1"
  local xbar="$work_dir/src/deps/axi/src/axi_xbar.sv"

  python3 - "$xbar" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

# Tabby/Verific 2020 rejects Cfg.* dimensions on AXI_BUS modport arrays.
# PSpin's pulp_cluster wrapper instantiates this interface with a fixed 3x3
# cluster crossbar and two address rules, so specialize only this worktree.
replacements = [
    (
        "  AXI_BUS.Slave                                                   slv_ports [Cfg.NoSlvPorts-1:0],",
        "  AXI_BUS.Slave                                                   slv_ports [2:0],",
    ),
    (
        "  AXI_BUS.Master                                                  mst_ports [Cfg.NoMstPorts-1:0],",
        "  AXI_BUS.Master                                                  mst_ports [2:0],",
    ),
    (
        "  input  rule_t [Cfg.NoAddrRules-1:0]                             addr_map_i,",
        "  input  rule_t [1:0]                                             addr_map_i,",
    ),
    (
        "  input  logic  [Cfg.NoSlvPorts-1:0]                              en_default_mst_port_i,",
        "  input  logic  [2:0]                                             en_default_mst_port_i,",
    ),
    (
        "  input  logic  [Cfg.NoSlvPorts-1:0][$clog2(Cfg.NoMstPorts)-1:0]  default_mst_port_i",
        "  input  logic  [2:0][1:0]                                       default_mst_port_i",
    ),
]

for old, new in replacements:
    if old not in text:
        raise SystemExit(f"expected pattern not found in {path}: {old}")
    text = text.replace(old, new)

path.write_text(text)
PY
}

patch_prepare_script_for_model() {
  local model="$1"
  local script="$2"

  if [[ "$model" != "pspin_pulp_cluster" ]]; then
    return
  fi

  python3 - "$script" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
lines = path.read_text().splitlines()
out = []
inserted_proc = False
for line in lines:
    if line.strip() in {"flatten", "prep -flatten"}:
        out.append(f"# skipped for Tabby Yosys 2020: {line.strip()}")
    elif line.strip().startswith("chformal -assert -assert2assume "):
        if not inserted_proc:
            out.append("# generate formal cells before applying non-flattened selectors")
            out.append("proc")
            inserted_proc = True
        line = line.replace("pulp_cluster_wrapper/*.", "*/")
        line = line.replace("pulp_cluster_wrapper/*", "*/*")
        out.append(line)
    else:
        out.append(line)
path.write_text("\n".join(out) + "\n")
PY
}

patch_cutpoints() {
  local script="$1"
  python3 - "$script" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    r"cutpoint t:\$mul t:\$mem_v2",
    r"cutpoint t:\$mul t:\$mem_v2 t:\$mem",
)
path.write_text(text)
PY
}

write_prepared_script() {
  local output="$1"
  cat >> "$output" <<'YOSYS'

# SBY-compatible preparation, restricted to commands supported by Tabby Yosys 2020.
proc
opt_clean
scc -select
simplemap
select -clear
memory_nordff
clk2fflogic
opt_clean
chformal -live -fair -cover -remove
opt_clean
check
setundef -undriven -anyseq
opt -fast
stat
write_rtlil ../model/design_prep.il
YOSYS
}

write_frontend_script() {
  local output="$1"
  cat >> "$output" <<'YOSYS'

# Keep Tabby/Verific work minimal; lower and optimize with native Yosys.
write_rtlil ../model/design_frontend.il
YOSYS
}

write_native_prepare_script() {
  local output="$1"
  local top="$2"
  cat > "$output" <<YOSYS
read_rtlil design_frontend.il
hierarchy -top $top

# SBY-compatible preparation after Verific import; no license needed here.
proc
opt_clean
scc -select
simplemap
select -clear
memory_nordff
clk2fflogic
opt_clean
chformal -live -fair -cover -remove
opt_clean
# The full PSpin cluster emits thousands of no-driver diagnostics here. That
# check is only diagnostic and dominates runtime, so keep the export path lean.
setundef -undriven -anyseq
opt -fast
stat
write_rtlil design_prep.il
YOSYS
}

write_btor_script() {
  local output="$1"
  local name="$2"
  cat > "$output" <<YOSYS
read_rtlil design_prep.il
hierarchy -check
delete */t:\$print
flatten
setundef -undriven -anyseq
opt -fast
delete -output
dffunmap
stat
write_btor -v -i $name.btor2.info $name.btor2
YOSYS
}

write_aiger_script() {
  local output="$1"
  local name="$2"
  cat > "$output" <<YOSYS
read_rtlil design_prep.il
delete */t:\$print
hierarchy -check
flatten
setundef -undriven -anyseq
setattr -unset keep
delete -output
opt -fast
techmap
opt -fast
memory_map
opt -fast
simplemap
dffunmap
aigmap
opt_clean
stat
write_aiger -I -B -zinit -map $name.aim -symbols $name.aig
write_aiger -ascii -I -B -zinit -map $name.ascii.aim -symbols $name.aag
YOSYS
}

patch_export_scripts_for_model() {
  local model="$1"
  local btor_script="$2"
  local aiger_script="$3"

  if [[ "$model" != "pspin_pulp_cluster" ]]; then
    return
  fi

  python3 - "$btor_script" "$aiger_script" <<'PY'
import sys
from pathlib import Path

for script in map(Path, sys.argv[1:]):
    text = script.read_text()
    text = text.replace("hierarchy -check\n", "")
    script.write_text(text)
PY
}

sanitize_rtlil_const_outputs() {
  local input="$1"
  local tmp="${input%.il}.sanitized.il"

  python3 "$repo_root/scripts/sanitize_rtlil_const_outputs.py" "$input" "$tmp"
  mv "$tmp" "$input"
}

compress_model_payloads() {
  local name="$1"
  gzip -9 -n -k -f \
    "$models_dir/$name.btor2" \
    "$models_dir/$name.aig" \
    "$models_dir/$name.aag"
  split_large_compressed_payloads \
    "$models_dir/$name.btor2.gz" \
    "$models_dir/$name.aig.gz" \
    "$models_dir/$name.aag.gz"
}

split_large_compressed_payloads() {
  python3 - "$@" <<'PY'
import sys
from pathlib import Path

limit = 90 * 1024 * 1024

for arg in sys.argv[1:]:
    path = Path(arg)
    for stale in path.parent.glob(path.name + ".part*"):
        stale.unlink()
    if not path.exists() or path.stat().st_size <= limit:
        continue

    with path.open("rb") as src:
        index = 0
        while True:
            chunk = src.read(limit)
            if not chunk:
                break
            part = path.with_name(f"{path.name}.part{index:02d}")
            part.write_bytes(chunk)
            index += 1
    path.unlink()
    print(f"split {path} into {index} part(s)")
PY
}

run_target() {
  local target="$1"
  local design="${target%%:*}"
  local task="${target#*:}"
  if [[ "$design" == "$task" ]]; then
    echo "target must be design:task, got '$target'" >&2
    return 1
  fi

  local sby_file
  sby_file="$(sby_file_for "$design")"

  local name
  name="$(model_name_for "$target")"
  local design_dir="$repo_root/$design"
  local work_dir="$work_root/$name"

  echo "==> $target"
  echo "    Tabby Yosys: $tabby_yosys_mode"
  echo "    Export Yosys: $export_yosys_mode"
  rm -rf "$work_dir"

  if [[ "$design" == "cv32e40x" ]]; then
    setup_cv32e40x_env
  fi

  (
    cd "$design_dir"
    "$sby_bin" -f --setup --yosys "$yosys_bin" -d "$work_dir" "$sby_file" "$task"
  )

  if [[ "$name" == "pspin_pulp_cluster" ]]; then
    patch_pspin_pulp_cluster_worktree "$work_dir"
  fi

  mkdir -p "$work_dir/model"

  local base_ys="$work_dir/src/export_prepare.ys"
  extract_script "$work_dir/config.sby" "$base_ys"
  (cd "$work_dir/src" && rewrite_frontend_commands "$base_ys" "$design")
  patch_cutpoints "$base_ys"
  patch_prepare_script_for_model "$name" "$base_ys"

  if [[ "$name" == "pspin_pulp_cluster" ]]; then
    write_frontend_script "$base_ys"
  else
    write_prepared_script "$base_ys"
  fi

  (
    cd "$work_dir/src"
    run_tabby_yosys -ql ../model/export_prepare.log export_prepare.ys
  )

  if [[ "$name" == "pspin_pulp_cluster" ]]; then
    write_native_prepare_script "$work_dir/model/export_native_prepare.ys" "pulp_cluster_wrapper"
    (
      cd "$work_dir/model"
      run_export_yosys -ql export_native_prepare.log export_native_prepare.ys
    )
    sanitize_rtlil_const_outputs "$work_dir/model/design_prep.il"
  fi

  write_btor_script "$work_dir/model/export_btor.ys" "$name"
  write_aiger_script "$work_dir/model/export_aiger.ys" "$name"
  patch_export_scripts_for_model \
    "$name" \
    "$work_dir/model/export_btor.ys" \
    "$work_dir/model/export_aiger.ys"

  (
    cd "$work_dir/model"
    run_export_yosys -ql export_btor.log export_btor.ys
    run_export_yosys -ql export_aiger.log export_aiger.ys
  )

  cp "$work_dir/model/$name.btor2" "$models_dir/"
  cp "$work_dir/model/$name.btor2.info" "$models_dir/"
  cp "$work_dir/model/$name.aig" "$models_dir/"
  cp "$work_dir/model/$name.aag" "$models_dir/"
  cp "$work_dir/model/$name.aim" "$models_dir/"
  cp "$work_dir/model/$name.ascii.aim" "$models_dir/"
  compress_model_payloads "$name"
}

for target in "${targets[@]}"; do
  run_target "$target"
done

echo
echo "Wrote models to $models_dir"
