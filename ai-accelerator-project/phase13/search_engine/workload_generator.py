#!/usr/bin/env python3
"""
workload_generator.py - Generates 100 Diverse Neural Network GEMM Workloads.

Covers 5 core architectural domains:
1. Small Edge GEMMs (20 workloads): Embedded/IoT, keyword spotting, sensor fusion.
2. Batched Inference (20 workloads): Speech recognition, recommendation embeddings, multi-sample inference.
3. Deep Reduction / Attention (20 workloads): Multi-head self-attention (Q*K^T, Attn*V), softmax projections.
4. Convolution im2col (20 workloads): ResNet, MobileNet, EfficientNet convolutional feature maps.
5. Large / Square Layers (20 workloads): Transformer feed-forward projections (MLP blocks, Bert/GPT).

Also generates a separate held-out set of 25 workloads for generalization validation.
"""

from typing import List, Dict, Any

def get_100_workloads() -> List[Dict[str, Any]]:
    workloads = []
    w_id = 1

    # =========================================================================
    # Category 1: Small Edge GEMMs (20 workloads)
    # M in [2..8], K in [8..32], N in [2..8]
    # =========================================================================
    edge_configs = [
        (4, 16, 4, "Edge Keyword Spotting (DS-CNN)"),
        (2, 16, 2, "Ultra-Low Power Wake-Word Detection"),
        (4, 8, 4, "Micro-MLP Layer 1"),
        (4, 24, 4, "Sensor Fusion Kalman-Filter Matrix"),
        (8, 16, 8, "Edge Audio Spectrogram Encoder"),
        (2, 32, 2, "ECG Anomaly Detection LSTM Gate"),
        (4, 32, 4, "IMU Motion Classifier Dense"),
        (6, 16, 6, "Edge Gesture Recognition RNN"),
        (8, 8, 8, "Vibration Sensor Feature Extractor"),
        (4, 12, 4, "TinyML Speech MLP Block 2"),
        (2, 24, 4, "Wearable Heart-Rate Filter"),
        (8, 24, 4, "Smart Meter Predictive Maintenance"),
        (6, 12, 6, "Low-Power Vision Trigger"),
        (4, 28, 4, "Acoustic Event Detector"),
        (8, 32, 4, "Edge Robot Odometry Matrix"),
        (4, 20, 8, "Drone Optical Flow Linear Layer"),
        (2, 12, 2, "Battery State-of-Charge Estimator"),
        (6, 20, 6, "Industrial Pressure Transducer Net"),
        (8, 12, 8, "Edge Bio-Signal Classifier"),
        (4, 16, 8, "Edge Camera ROI Localizer")
    ]
    for M, K, N, desc in edge_configs:
        workloads.append({
            "id": w_id, "category": "Small Edge",
            "name": f"Edge_GEMM_{w_id}", "M": M, "K": K, "N": N, "description": desc
        })
        w_id += 1

    # =========================================================================
    # Category 2: Batched Inference (20 workloads)
    # M in [16..128], K in [4..16], N in [8..64]
    # =========================================================================
    batch_configs = [
        (32, 4, 16, "Batch-32 RecSys DLRM Bottom-MLP"),
        (64, 4, 64, "Batch-64 Recommendation Sparse Embedding"),
        (128, 4, 32, "Batch-128 Fast Audio Mel-Filterbank"),
        (16, 8, 16, "Batch-16 Speech Conformer Subsampling"),
        (32, 8, 32, "Batch-32 CTC Acoustic Model Head"),
        (64, 8, 16, "Batch-64 Text Sentiment BiLSTM"),
        (128, 8, 64, "Batch-128 Click-Through Rate Predictor"),
        (16, 12, 32, "Batch-16 Fraud Detection Graph Node Net"),
        (32, 12, 16, "Batch-32 Real-time TTS Vocoder Gate"),
        (64, 12, 48, "Batch-64 Video Frame Feature Aggregator"),
        (128, 12, 32, "Batch-128 Multi-Task Embedding Projector"),
        (16, 16, 64, "Batch-16 Language Model Softmax Logits"),
        (32, 16, 48, "Batch-32 User-Profile MLP Layer"),
        (64, 16, 32, "Batch-64 Re-Ranking Dense Layer"),
        (128, 16, 16, "Batch-128 Latency-Critical Server Ingress"),
        (48, 4, 32, "Batch-48 Ad-Click Feature Interaction"),
        (80, 8, 24, "Batch-80 Telemetry Stream Classifier"),
        (96, 4, 48, "Batch-96 Search Query Token Scoring"),
        (112, 8, 32, "Batch-112 Video Recommendation Head"),
        (64, 16, 64, "Batch-64 Dense Multi-Modal Mixer")
    ]
    for M, K, N, desc in batch_configs:
        workloads.append({
            "id": w_id, "category": "Batched Inference",
            "name": f"Batch_GEMM_{w_id}", "M": M, "K": K, "N": N, "description": desc
        })
        w_id += 1

    # =========================================================================
    # Category 3: Deep Reduction / Attention (20 workloads)
    # M in [1..8], K in [32..256], N in [4..16]
    # =========================================================================
    attn_configs = [
        (4, 64, 4, "Multi-Head Attention Head (d_k=64)"),
        (1, 128, 1, "Single Token Autoregressive Query Vector"),
        (4, 128, 4, "Attention Key-Value Context Reduction"),
        (8, 64, 8, "Self-Attention Score Q*K^T (seq=8)"),
        (2, 256, 4, "Long-Context Attention Projection"),
        (4, 96, 4, "Vision Transformer Small Patch Attn"),
        (1, 256, 8, "Transformer Decoder Cross-Attention"),
        (8, 128, 4, "Sequence-to-Sequence Encoder Attn"),
        (4, 192, 4, "ViT-Base Key Projection Reduction"),
        (2, 64, 8, "Two-Token Speculative Decoding Step"),
        (8, 96, 8, "Audio Perceiver Cross-Attention"),
        (4, 160, 4, "LLaMA-7B Head Projection Tile"),
        (1, 64, 16, "Token Generation Output Step"),
        (4, 256, 2, "Extreme Reduction Context Filter"),
        (8, 160, 4, "Speech Transformer Attention Head"),
        (2, 128, 6, "Dialogue State Softmax Projection"),
        (4, 80, 8, "Multi-Query Attention (MQA) Tile"),
        (8, 192, 8, "Grouped-Query Attention (GQA) Head"),
        (2, 192, 4, "Code-Generation Autoregressive Cache"),
        (4, 224, 4, "Sparse Attention KV-Merge")
    ]
    for M, K, N, desc in attn_configs:
        workloads.append({
            "id": w_id, "category": "Deep Reduction / Attention",
            "name": f"Attn_GEMM_{w_id}", "M": M, "K": K, "N": N, "description": desc
        })
        w_id += 1

    # =========================================================================
    # Category 4: Convolution im2col (20 workloads)
    # ResNet/MobileNet shapes: M in [16..196], K in [9..144], N in [16..64]
    # =========================================================================
    conv_configs = [
        (16, 36, 16, "ResNet Block 1 (3x3 conv, C_in=4, C_out=16)"),
        (49, 18, 32, "MobileNetV2 Depthwise Separable Pointwise"),
        (64, 27, 32, "ResNet Bottleneck 1x1 Expansion"),
        (36, 36, 64, "ResNet-50 Layer 2 3x3 Conv Tile"),
        (196, 9, 16, "VGG Early 3x3 Low-Channel Conv"),
        (64, 72, 32, "EfficientNet-B0 MBConv3 Expansion"),
        (25, 144, 48, "ResNet High-Channel Late-Stage Conv"),
        (100, 18, 32, "MobileNet Inverted Residual 1x1"),
        (49, 36, 48, "U-Net Decoder Skip-Connection Conv"),
        (64, 54, 32, "YOLOv8 Backbone C2f Feature Map"),
        (81, 27, 64, "SSD Object Detector Head Conv"),
        (36, 108, 32, "ConvNeXt 7x7 Depthwise Pointwise"),
        (144, 9, 32, "SegNet Semantic Segmentation Bottleneck"),
        (49, 72, 64, "DenseNet DenseBlock 3x3 Conv"),
        (64, 36, 48, "MobileNetV3 Hard-Swish 3x3 Conv"),
        (25, 108, 64, "ResNeXt Grouped Convolution Block"),
        (100, 36, 32, "Action Recognition 2D Spatial Conv"),
        (81, 54, 48, "Medical Image Segmentation Conv3D Slice"),
        (144, 18, 16, "Super-Resolution Sub-Pixel Conv"),
        (36, 144, 64, "Deep Optical Flow Warping Conv")
    ]
    for M, K, N, desc in conv_configs:
        workloads.append({
            "id": w_id, "category": "Convolution im2col",
            "name": f"Conv_GEMM_{w_id}", "M": M, "K": K, "N": N, "description": desc
        })
        w_id += 1

    # =========================================================================
    # Category 5: Large / Square Transformer layers (20 workloads)
    # M, K, N in [32..128]
    # =========================================================================
    square_configs = [
        (32, 32, 32, "Transformer MLP Intermediate Block 32x32"),
        (64, 64, 64, "BERT-Base Feed-Forward Projection 64x64"),
        (48, 48, 48, "RoBERTa Hidden State Transformation"),
        (64, 32, 64, "GPT-2 Down-Projection Linear Tile"),
        (32, 64, 32, "T5 Encoder Self-Attention Linear"),
        (64, 96, 64, "Electra Discriminator Intermediate"),
        (80, 80, 80, "DistilBERT Layer 3 Feed-Forward"),
        (96, 64, 96, "ALBERT Shared Parameter Layer"),
        (64, 128, 64, "Vision Transformer MLP Up-Projection"),
        (128, 64, 64, "Transformer Batched Sequence Output"),
        (48, 96, 48, "Speech Conformer Feed-Forward Half-Step"),
        (64, 64, 128, "Bilinear Pooling Layer Transformation"),
        (96, 96, 96, "Swin Transformer Patch Merging Dense"),
        (112, 64, 80, "Cross-Lingual XLM-R Transformer Layer"),
        (64, 80, 64, "Audio Spectrogram Transformer MLP"),
        (128, 32, 128, "Batch-128 Embedding Dimension Projection"),
        (80, 64, 80, "DeBERTa Disentangled Attention Layer"),
        (64, 112, 64, "Multi-Head Cross-Attention Linear Output"),
        (96, 80, 96, "Longformer Local Attention Linear"),
        (128, 128, 128, "Full Megatron-Style GEMM Sub-Block")
    ]
    for M, K, N, desc in square_configs:
        workloads.append({
            "id": w_id, "category": "Large / Square Layers",
            "name": f"Square_GEMM_{w_id}", "M": M, "K": K, "N": N, "description": desc
        })
        w_id += 1

    assert len(workloads) == 100, f"Expected 100 workloads, got {len(workloads)}"
    return workloads


def get_heldout_25_workloads() -> List[Dict[str, Any]]:
    """
    Held-out unseen workloads across all categories to test generalization.
    """
    configs = [
        # 5 unseen edge
        (3, 18, 3, "Unseen Edge Bio-Patch Monitor"),
        (5, 14, 5, "Unseen Edge Smart Thermostat"),
        (7, 22, 5, "Unseen Edge Drone Gyro Stabilizer"),
        (4, 30, 2, "Unseen Edge Audio Keyword Detector"),
        (2, 28, 6, "Unseen Edge Micropower Accelerometer"),
        # 5 unseen batch
        (24, 6, 20, "Unseen Batch Re-Ranker Tier 2"),
        (40, 10, 36, "Unseen Batch Speech Endpoint Detector"),
        (72, 6, 40, "Unseen Batch User Churn Classifier"),
        (88, 14, 28, "Unseen Batch Session Embedding"),
        (104, 10, 56, "Unseen Batch Real-Time Bidding Linear"),
        # 5 unseen deep reduction
        (3, 72, 3, "Unseen ViT Distilled Query Attention"),
        (6, 112, 6, "Unseen Cross-Modal Audio-Video Reducer"),
        (2, 144, 4, "Unseen Diffusion Timestep Attention"),
        (5, 176, 5, "Unseen Long-Document Chunk Reducer"),
        (1, 208, 4, "Unseen Sparse Retrieval Context Scorer"),
        # 5 unseen conv
        (28, 45, 24, "Unseen Conv Pose Estimation Heatmap"),
        (56, 30, 40, "Unseen Conv LiDAR Point Cloud Feature"),
        (70, 40, 32, "Unseen Conv Stereo Disparity 2D Conv"),
        (110, 20, 24, "Unseen Conv OCR Text Line Recognizer"),
        (45, 90, 56, "Unseen Conv Autonomous Driving Perception"),
        # 5 unseen square
        (40, 56, 40, "Unseen Transformer Intermediate 40x56"),
        (72, 72, 72, "Unseen Dense MLP 72x72"),
        (88, 56, 88, "Unseen Code Llama Feed-Forward"),
        (56, 88, 56, "Unseen Speech Conformer Block 56x88"),
        (100, 100, 100, "Unseen Multi-Modal Embedding 100x100")
    ]

    heldout = []
    for idx, (M, K, N, desc) in enumerate(configs, 1):
        heldout.append({
            "id": idx, "name": f"Heldout_GEMM_{idx}",
            "M": M, "K": K, "N": N, "description": desc
        })
    return heldout
