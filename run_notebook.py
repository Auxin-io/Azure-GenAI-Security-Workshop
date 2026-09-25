"""Execute a notebook's code cells in order (no Jupyter needed) - used to verify the notebooks.

    python run_notebook.py 01_architecture_and_data.ipynb
"""
import json
import sys
import traceback
from pathlib import Path

# Foundry answers carry citation markers in CJK brackets. A Windows console defaults to
# cp1252 and dies on them, which looks like a notebook bug and is not one - Colab and
# Jupyter are both UTF-8.
for stream in (sys.stdout, sys.stderr):
    try:
        stream.reconfigure(encoding='utf-8', errors='replace')
    except (AttributeError, ValueError):
        pass

path = Path(sys.argv[1])
cells = [c for c in json.loads(path.read_text(encoding="utf-8"))["cells"] if c["cell_type"] == "code"]
ns = {}
for i, c in enumerate(cells, 1):
    src = "".join(c["source"]) if isinstance(c["source"], list) else c["source"]
    print(f"\n===== cell {i}/{len(cells)} =====")
    try:
        exec(compile(src, f"{path.name}#cell{i}", "exec"), ns)
    except SystemExit as e:
        print("SystemExit:", e)
        sys.exit(1)
    except Exception:
        traceback.print_exc()
        sys.exit(1)
print(f"\nOK - {path.name}: {len(cells)} cells ran")
