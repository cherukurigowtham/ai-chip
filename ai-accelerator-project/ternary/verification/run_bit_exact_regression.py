"""
run_bit_exact_regression.py - Cycle-accurate generator matching RTL register stages.
"""

import os
import sys
import random
import numpy as np
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "../sim")))
from ternary_quant import decode_hardware_weight, ENC_ZERO, ENC_POS_ONE, ENC_NEG_ONE

def generate_vectors(num_cycles: int = 1000):
    np.random.seed(1337)
    random.seed(1337)
    
    current_w_reg = 0 # reset state (2'b00)
    vectors = []
    
    for cycle in range(num_cycles):
        weight_load = (random.random() < 0.08) or (cycle == 0)
        weight_in = random.choice([ENC_ZERO, ENC_POS_ONE, ENC_NEG_ONE, 0b11])
        act_in = int(np.random.randint(-32768, 32768))
        psum_in = int(np.random.randint(-1000000, 1000000))
        enable = 1 if (random.random() > 0.05) else 0 # 95% enable
        
        # Computation in cycle t uses current_w_reg (from previous cycle)
        w_val = decode_hardware_weight(current_w_reg)
        is_zero = (w_val == 0)
        
        if is_zero:
            effective_addend = 0
            exp_skip = 1
        elif w_val == 1:
            effective_addend = act_in
            exp_skip = 0
        else: # -1
            effective_addend = -act_in
            exp_skip = 0
            
        exp_psum = np.int32(psum_in + effective_addend)
        exp_act = act_in
        
        vectors.append({
            "cycle": cycle,
            "enable": enable,
            "weight_load": 1 if weight_load else 0,
            "weight_in": weight_in,
            "act_in": act_in,
            "psum_in": psum_in,
            "exp_act": exp_act,
            "exp_psum": int(exp_psum),
            "exp_skip": exp_skip
        })
        
        # At clock edge, w_reg updates if enable and weight_load
        if enable and weight_load:
            current_w_reg = weight_in
            
    return vectors

def write_hex_files(vectors, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "stimulus.txt"), "w") as f:
        for v in vectors:
            act_u16 = v["act_in"] & 0xFFFF
            psum_u32 = v["psum_in"] & 0xFFFFFFFF
            exp_act_u16 = v["exp_act"] & 0xFFFF
            exp_psum_u32 = v["exp_psum"] & 0xFFFFFFFF
            f.write(f"{v['enable']} {v['weight_load']} {v['weight_in']:01x} {act_u16:04x} {psum_u32:08x} {exp_act_u16:04x} {exp_psum_u32:08x} {v['exp_skip']}\n")

if __name__ == "__main__":
    out_dir = os.path.abspath(os.path.dirname(__file__))
    vectors = generate_vectors(1000)
    write_hex_files(vectors, out_dir)
    print(f"Generated {len(vectors)} bit-exact verification vectors at {out_dir}/stimulus.txt")
