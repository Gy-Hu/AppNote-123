# Exported Models

These artifacts were generated with `scripts/export_models.sh` using the
Tabby CAD Yosys/Verific frontend and a modern `sby --setup` flow.

Included benchmark models:

- `veer.*`
- `veer_axi.*`
- `cv32e40x.*`
- `pspin_riscv_core.*`
- `pspin_core_region.*`
- `pspin_pulp_cluster.*`

Each model set contains compressed BTOR2 plus compressed binary/ascii AIGER
outputs and the corresponding AIGER symbol maps. The large payloads are stored
as ordinary Git files with gzip compression:

- `*.btor2.gz`
- `*.aig.gz`
- `*.aag.gz`

For payloads that still exceed GitHub's normal file size limit after gzip,
the gzip stream is committed as ordered parts and the whole `.gz` is omitted:

- `*.btor2.gz.partNN`
- `*.aig.gz.partNN`
- `*.aag.gz.partNN`

Reassemble a split payload with `cat exports/models/name.ext.gz.part* > name.ext.gz`.
Use `gunzip -k exports/models/*.gz` on unsplit payloads, or on reassembled
payloads, to materialize raw solver inputs locally.
Raw `*.btor2`, `*.aig`, and `*.aag` files are ignored because they are generated
or decompressed artifacts.

Excluded local outputs:

- `pspin_soc_dma_wrap.*`: the AIGER export collapses to a degenerate model
  (`M=1707, I=1707, L=0, A=0, B=1`) with no meaningful state or property cone.
