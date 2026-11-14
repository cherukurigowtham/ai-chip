# BitNet-130 Carrier Board: Turnkey SMT Manufacturing Package

This directory provides the production-ready Bill of Materials (BOM) and Component Placement List (CPL) for ordering assembled PCB modules from **JLCPCB**, **PCBWay**, or **Seeed Fusion**.

---

## 1. Board Specifications

* **Dimensions**: $55.0\,\text{mm} \times 24.0\,\text{mm}$ (Breadboard-compatible 0.1" pitch dual-row pin headers)
* **Layer Count**: 4-Layer FR-4 (Signal - GND Plane - 3.3V/1.8V Split Power Plane - Signal)
* **PCB Thickness**: $1.6\,\text{mm}$
* **Outer Copper Weight**: $1.0\,\text{oz}$ ($35\,\mu\text{m}$)
* **Surface Finish**: **ENIG (Electroless Nickel Immersion Gold)** for high-speed signal integrity
* **Solder Mask**: Matte Black (or Matte Green)
* **Silkscreen**: White high-resolution legend

---

## 2. Production Files for SMT Assembly

| File | Format | Purpose |
| :--- | :--- | :--- |
| [`jlcpcb_bom.csv`](jlcpcb_bom.csv) | CSV (Standard LCSC part mapping) | Component Bill of Materials for automated SMT pick-and-place |
| [`jlcpcb_cpl.csv`](jlcpcb_cpl.csv) | CSV (Centroid XY and rotation) | Component Placement List for automated pick-and-place machines |
| [`netlist.net`](netlist.net) | KiCad Netlist format | Complete electrical connectivity definition |
| [`bitnet130_carrier.kicad_pro`](bitnet130_carrier.kicad_pro) | KiCad 7.0+ Project | Native schematic and board design files |

---

## 3. Turnkey SMT Ordering Steps (JLCPCB)

1. **Upload Gerber Package**:
   - In JLCPCB quote page, upload the zipped Gerber files.
   - Select: **4 Layers**, **1.6mm thickness**, **ENIG finish**, **JLC04161H-7628 stackup**.
2. **Enable SMT Assembly**:
   - Toggle **"SMT Assembly"** ON (Top Side assembly).
   - Tooling holes: Added by JLCPCB.
3. **Upload Assembly Files**:
   - Upload [`jlcpcb_bom.csv`](jlcpcb_bom.csv) for BOM.
   - Upload [`jlcpcb_cpl.csv`](jlcpcb_cpl.csv) for CPL / Centroid file.
4. **Component Verification**:
   - JLCPCB will automatically match all 13 unique part numbers directly to the verified LCSC catalog (e.g. `C2040` for RP2040, `C97521` for 16MB QSPI Flash, `C397342` for 3.3V LDO, `C123490` for 1.8V LDO).
5. **Review 3D Placement**:
   - Confirm component alignment on the 3D visual preview.
   - Click **Save to Cart** and place order.
