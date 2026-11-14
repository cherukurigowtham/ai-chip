from setuptools import setup, find_packages

setup(
    name="bitnet-accel",
    version="3.0.0",
    description="Universal Multiplier-Free AI Silicon SDK, Frontier Model Compiler & Runtime",
    long_description=open("README.md").read(),
    long_description_content_type="text/markdown",
    author="Cherukuri Gowtham",
    author_email="cherukurigowtham851@gmail.com",
    url="https://github.com/cherukurigowtham/ai-chip",
    license="Apache-2.0",
    packages=find_packages(where="ai-accelerator-project/sdk"),
    package_dir={"": "ai-accelerator-project/sdk"},
    py_modules=[
        "torch_bitnet_backend",
        "huggingface_adapter",
        "frontier_model_adapter",
        "bitnet_server",
        "bitnet_cli",
        "bitnet_compiler",
        "export_bitnet_onnx",
        "bitnet_x16_simulator"
    ],
    install_requires=[
        "torch>=2.0.0",
        "numpy>=1.20.0"
    ],
    entry_points={
        "console_scripts": [
            "bitnet = bitnet_cli:main",
            "bitnet-cli = bitnet_cli:main",
            "bitnet-server = bitnet_server:main",
        ],
    },
    classifiers=[
        "Programming Language :: Python :: 3",
        "Topic :: Scientific/Engineering :: Artificial Intelligence",
        "Topic :: Hardware :: Silicon Accelerator",
        "Operating System :: OS Independent",
    ],
    python_requires=">=3.8",
)
