// ============================================================================
// Behavioral Simulation Models for Nangate 45nm Standard Cells
// ============================================================================
`timescale 1ns/1ps


module DFF_X1 (input CK, input D, output reg Q = 1'b0, output QN);
    always @(posedge CK) Q <= D;
    assign QN = ~Q;
endmodule

module DFF_X2 (input CK, input D, output reg Q = 1'b0, output QN);
    always @(posedge CK) Q <= D;
    assign QN = ~Q;
endmodule

module DFFR_X1 (input CK, input D, input RN, output reg Q = 1'b0, output QN);
    always @(posedge CK or negedge RN) begin
        if (!RN) Q <= 1'b0;
        else     Q <= D;
    end
    assign QN = ~Q;
endmodule

module DFFR_X2 (input CK, input D, input RN, output reg Q = 1'b0, output QN);
    always @(posedge CK or negedge RN) begin
        if (!RN) Q <= 1'b0;
        else     Q <= D;
    end
    assign QN = ~Q;
endmodule

module DFFS_X1 (input CK, input D, input SN, output reg Q = 1'b0, output QN);
    always @(posedge CK or negedge SN) begin
        if (!SN) Q <= 1'b1;
        else     Q <= D;
    end
    assign QN = ~Q;
endmodule

module DFFS_X2 (input CK, input D, input SN, output reg Q = 1'b0, output QN);
    always @(posedge CK or negedge SN) begin
        if (!SN) Q <= 1'b1;
        else     Q <= D;
    end
    assign QN = ~Q;
endmodule

module FA_X1 (input A, input B, input CI, output S, output CO);
    assign S = A ^ B ^ CI;
    assign CO = (A & B) | (B & CI) | (A & CI);
endmodule

module HA_X1 (input A, input B, output S, output CO);
    assign S = A ^ B;
    assign CO = A & B;
endmodule

module AND2_X1 (input A1, input A2, output ZN);
  assign ZN = (A1 & A2);
endmodule

module AND2_X2 (input A1, input A2, output ZN);
  assign ZN = (A1 & A2);
endmodule

module AND2_X4 (input A1, input A2, output ZN);
  assign ZN = (A1 & A2);
endmodule

module AND3_X1 (input A1, input A2, input A3, output ZN);
  assign ZN = ((A1 & A2) & A3);
endmodule

module AND3_X2 (input A1, input A2, input A3, output ZN);
  assign ZN = ((A1 & A2) & A3);
endmodule

module AND3_X4 (input A1, input A2, input A3, output ZN);
  assign ZN = ((A1 & A2) & A3);
endmodule

module AND4_X1 (input A1, input A2, input A3, input A4, output ZN);
  assign ZN = (((A1 & A2) & A3) & A4);
endmodule

module AND4_X2 (input A1, input A2, input A3, input A4, output ZN);
  assign ZN = (((A1 & A2) & A3) & A4);
endmodule

module AND4_X4 (input A1, input A2, input A3, input A4, output ZN);
  assign ZN = (((A1 & A2) & A3) & A4);
endmodule

module AOI211_X1 (input A, input B, input C1, input C2, output ZN);
  assign ZN = ~(((C1 & C2) | B) | A);
endmodule

module AOI211_X2 (input A, input B, input C1, input C2, output ZN);
  assign ZN = ~(((C1 & C2) | B) | A);
endmodule

module AOI211_X4 (input A, input B, input C1, input C2, output ZN);
  assign ZN = ~(~(~(((C1 & C2) | B) | A)));
endmodule

module AOI21_X1 (input A, input B1, input B2, output ZN);
  assign ZN = ~(A | (B1 & B2));
endmodule

module AOI21_X2 (input A, input B1, input B2, output ZN);
  assign ZN = ~(A | (B1 & B2));
endmodule

module AOI21_X4 (input A, input B1, input B2, output ZN);
  assign ZN = ~(A | (B1 & B2));
endmodule

module AOI221_X1 (input A, input B1, input B2, input C1, input C2, output ZN);
  assign ZN = ~(((C1 & C2) | A) | (B1 & B2));
endmodule

module AOI221_X2 (input A, input B1, input B2, input C1, input C2, output ZN);
  assign ZN = ~(((C1 & C2) | A) | (B1 & B2));
endmodule

module AOI221_X4 (input A, input B1, input B2, input C1, input C2, output ZN);
  assign ZN = ~(~(~(((C1 & C2) | A) | (B1 & B2))));
endmodule

module AOI222_X1 (input A1, input A2, input B1, input B2, input C1, input C2, output ZN);
  assign ZN = ~(((A1 & A2) | (B1 & B2)) | (C1 & C2));
endmodule

module AOI222_X2 (input A1, input A2, input B1, input B2, input C1, input C2, output ZN);
  assign ZN = ~(((A1 & A2) | (B1 & B2)) | (C1 & C2));
endmodule

module AOI222_X4 (input A1, input A2, input B1, input B2, input C1, input C2, output ZN);
  assign ZN = ~(~(~(((A1 & A2) | (B1 & B2)) | (C1 & C2))));
endmodule

module AOI22_X1 (input A1, input A2, input B1, input B2, output ZN);
  assign ZN = ~((A1 & A2) | (B1 & B2));
endmodule

module AOI22_X2 (input A1, input A2, input B1, input B2, output ZN);
  assign ZN = ~((A1 & A2) | (B1 & B2));
endmodule

module AOI22_X4 (input A1, input A2, input B1, input B2, output ZN);
  assign ZN = ~((A1 & A2) | (B1 & B2));
endmodule

module BUF_X1 (input A, output Z);
  assign Z = A;
endmodule

module BUF_X16 (input A, output Z);
  assign Z = A;
endmodule

module BUF_X2 (input A, output Z);
  assign Z = A;
endmodule

module BUF_X32 (input A, output Z);
  assign Z = A;
endmodule

module BUF_X4 (input A, output Z);
  assign Z = A;
endmodule

module BUF_X8 (input A, output Z);
  assign Z = A;
endmodule

module CLKBUF_X1 (input A, output Z);
  assign Z = A;
endmodule

module CLKBUF_X2 (input A, output Z);
  assign Z = A;
endmodule

module CLKBUF_X3 (input A, output Z);
  assign Z = A;
endmodule

module CLKGATETST_X1 (input CK, input E, input SE, output GCK);
endmodule

module CLKGATETST_X2 (input CK, input E, input SE, output GCK);
endmodule

module CLKGATETST_X4 (input CK, input E, input SE, output GCK);
endmodule

module CLKGATETST_X8 (input CK, input E, input SE, output GCK);
endmodule

module CLKGATE_X1 (input CK, input E, output GCK);
endmodule

module CLKGATE_X2 (input CK, input E, output GCK);
endmodule

module CLKGATE_X4 (input CK, input E, output GCK);
endmodule

module CLKGATE_X8 (input CK, input E, output GCK);
endmodule

module INV_X1 (input A, output ZN);
  assign ZN = ~A;
endmodule

module INV_X16 (input A, output ZN);
  assign ZN = ~A;
endmodule

module INV_X2 (input A, output ZN);
  assign ZN = ~A;
endmodule

module INV_X32 (input A, output ZN);
  assign ZN = ~A;
endmodule

module INV_X4 (input A, output ZN);
  assign ZN = ~A;
endmodule

module INV_X8 (input A, output ZN);
  assign ZN = ~A;
endmodule

module MUX2_X1 (input A, input B, input S, output Z);
  assign Z = ((S & B) | (A & ~S));
endmodule

module MUX2_X2 (input A, input B, input S, output Z);
  assign Z = ((S & B) | (A & ~S));
endmodule

module NAND2_X1 (input A1, input A2, output ZN);
  assign ZN = ~(A1 & A2);
endmodule

module NAND2_X2 (input A1, input A2, output ZN);
  assign ZN = ~(A1 & A2);
endmodule

module NAND2_X4 (input A1, input A2, output ZN);
  assign ZN = ~(A1 & A2);
endmodule

module NAND3_X1 (input A1, input A2, input A3, output ZN);
  assign ZN = ~((A1 & A2) & A3);
endmodule

module NAND3_X2 (input A1, input A2, input A3, output ZN);
  assign ZN = ~((A1 & A2) & A3);
endmodule

module NAND3_X4 (input A1, input A2, input A3, output ZN);
  assign ZN = ~((A1 & A2) & A3);
endmodule

module NAND4_X1 (input A1, input A2, input A3, input A4, output ZN);
  assign ZN = ~(((A1 & A2) & A3) & A4);
endmodule

module NAND4_X2 (input A1, input A2, input A3, input A4, output ZN);
  assign ZN = ~(((A1 & A2) & A3) & A4);
endmodule

module NAND4_X4 (input A1, input A2, input A3, input A4, output ZN);
  assign ZN = ~(((A1 & A2) & A3) & A4);
endmodule

module NOR2_X1 (input A1, input A2, output ZN);
  assign ZN = ~(A1 | A2);
endmodule

module NOR2_X2 (input A1, input A2, output ZN);
  assign ZN = ~(A1 | A2);
endmodule

module NOR2_X4 (input A1, input A2, output ZN);
  assign ZN = ~(A1 | A2);
endmodule

module NOR3_X1 (input A1, input A2, input A3, output ZN);
  assign ZN = ~((A1 | A2) | A3);
endmodule

module NOR3_X2 (input A1, input A2, input A3, output ZN);
  assign ZN = ~((A1 | A2) | A3);
endmodule

module NOR3_X4 (input A1, input A2, input A3, output ZN);
  assign ZN = ~((A1 | A2) | A3);
endmodule

module NOR4_X1 (input A1, input A2, input A3, input A4, output ZN);
  assign ZN = ~(((A1 | A2) | A3) | A4);
endmodule

module NOR4_X2 (input A1, input A2, input A3, input A4, output ZN);
  assign ZN = ~(((A1 | A2) | A3) | A4);
endmodule

module NOR4_X4 (input A1, input A2, input A3, input A4, output ZN);
  assign ZN = ~(((A1 | A2) | A3) | A4);
endmodule

module OAI211_X1 (input A, input B, input C1, input C2, output ZN);
  assign ZN = ~(((C1 | C2) & A) & B);
endmodule

module OAI211_X2 (input A, input B, input C1, input C2, output ZN);
  assign ZN = ~(((C1 | C2) & A) & B);
endmodule

module OAI211_X4 (input A, input B, input C1, input C2, output ZN);
  assign ZN = ~(((C1 | C2) & A) & B);
endmodule

module OAI21_X1 (input A, input B1, input B2, output ZN);
  assign ZN = ~(A & (B1 | B2));
endmodule

module OAI21_X2 (input A, input B1, input B2, output ZN);
  assign ZN = ~(A & (B1 | B2));
endmodule

module OAI21_X4 (input A, input B1, input B2, output ZN);
  assign ZN = ~(A & (B1 | B2));
endmodule

module OAI221_X1 (input A, input B1, input B2, input C1, input C2, output ZN);
  assign ZN = ~(((C1 | C2) & A) & (B1 | B2));
endmodule

module OAI221_X2 (input A, input B1, input B2, input C1, input C2, output ZN);
  assign ZN = ~(((C1 | C2) & A) & (B1 | B2));
endmodule

module OAI221_X4 (input A, input B1, input B2, input C1, input C2, output ZN);
  assign ZN = ~(~(~(((C1 | C2) & A) & (B1 | B2))));
endmodule

module OAI222_X1 (input A1, input A2, input B1, input B2, input C1, input C2, output ZN);
  assign ZN = ~(((A1 | A2) & (B1 | B2)) & (C1 | C2));
endmodule

module OAI222_X2 (input A1, input A2, input B1, input B2, input C1, input C2, output ZN);
  assign ZN = ~(((A1 | A2) & (B1 | B2)) & (C1 | C2));
endmodule

module OAI222_X4 (input A1, input A2, input B1, input B2, input C1, input C2, output ZN);
  assign ZN = ~(~(~(((A1 | A2) & (B1 | B2)) & (C1 | C2))));
endmodule

module OAI22_X1 (input A1, input A2, input B1, input B2, output ZN);
  assign ZN = ~((A1 | A2) & (B1 | B2));
endmodule

module OAI22_X2 (input A1, input A2, input B1, input B2, output ZN);
  assign ZN = ~((A1 | A2) & (B1 | B2));
endmodule

module OAI22_X4 (input A1, input A2, input B1, input B2, output ZN);
  assign ZN = ~((A1 | A2) & (B1 | B2));
endmodule

module OAI33_X1 (input A1, input A2, input A3, input B1, input B2, input B3, output ZN);
  assign ZN = ~(((A1 | A2) | A3) & ((B1 | B2) | B3));
endmodule

module OR2_X1 (input A1, input A2, output ZN);
  assign ZN = (A1 | A2);
endmodule

module OR2_X2 (input A1, input A2, output ZN);
  assign ZN = (A1 | A2);
endmodule

module OR2_X4 (input A1, input A2, output ZN);
  assign ZN = (A1 | A2);
endmodule

module OR3_X1 (input A1, input A2, input A3, output ZN);
  assign ZN = ((A1 | A2) | A3);
endmodule

module OR3_X2 (input A1, input A2, input A3, output ZN);
  assign ZN = ((A1 | A2) | A3);
endmodule

module OR3_X4 (input A1, input A2, input A3, output ZN);
  assign ZN = ((A1 | A2) | A3);
endmodule

module OR4_X1 (input A1, input A2, input A3, input A4, output ZN);
  assign ZN = (((A1 | A2) | A3) | A4);
endmodule

module OR4_X2 (input A1, input A2, input A3, input A4, output ZN);
  assign ZN = (((A1 | A2) | A3) | A4);
endmodule

module OR4_X4 (input A1, input A2, input A3, input A4, output ZN);
  assign ZN = (((A1 | A2) | A3) | A4);
endmodule

module TBUF_X1 (input A, input EN, output Z);
  assign Z = A;
endmodule

module TBUF_X16 (input A, input EN, output Z);
  assign Z = A;
endmodule

module TBUF_X2 (input A, input EN, output Z);
  assign Z = A;
endmodule

module TBUF_X4 (input A, input EN, output Z);
  assign Z = A;
endmodule

module TBUF_X8 (input A, input EN, output Z);
  assign Z = A;
endmodule

module TINV_X1 (input EN, input I, output ZN);
  assign ZN = ~I;
endmodule

module XNOR2_X1 (input A, input B, output ZN);
  assign ZN = ~(A ^ B);
endmodule

module XNOR2_X2 (input A, input B, output ZN);
  assign ZN = ~(A ^ B);
endmodule

module XOR2_X1 (input A, input B, output Z);
  assign Z = (A ^ B);
endmodule

module XOR2_X2 (input A, input B, output Z);
  assign Z = (A ^ B);
endmodule
