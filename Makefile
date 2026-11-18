# ============================================================================
# Lin286 Build System
# Target Architecture: Intel 80286 16-Bit Protected Virtual Address Mode
# ============================================================================

NASM       ?= nasm
NDISASM    ?= ndisasm
PYTHON     ?= python3

BOOT_DIR   := boot
KERNEL_DIR := kernel
BUILD_DIR  := build
TOOLS_DIR  := tools

BOOTSECT_SRC := $(BOOT_DIR)/bootsect.asm
SETUP_SRC    := $(BOOT_DIR)/setup.asm
KERNEL_SRCS  := $(wildcard $(KERNEL_DIR)/arch/i286/*.asm) $(wildcard $(KERNEL_DIR)/mm/*.asm) $(wildcard $(KERNEL_DIR)/sched/*.asm) $(wildcard $(KERNEL_DIR)/sys/*.asm)

BOOTSECT_BIN := $(BUILD_DIR)/bootsect.bin
SETUP_BIN    := $(BUILD_DIR)/setup.bin
KERNEL_BIN   := $(BUILD_DIR)/kernel.bin
KERNEL_DIS   := $(BUILD_DIR)/kernel.dis
FLOPPY_IMG   := $(BUILD_DIR)/floppy.img

.PHONY: all clean gatekeeper disasm test test-bochs help

all: gatekeeper $(FLOPPY_IMG) disasm verify-disasm

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

# Gatekeeper check on all assembly sources
gatekeeper:
	@$(PYTHON) $(TOOLS_DIR)/check_286_opcodes.py --asm $(BOOT_DIR) $(KERNEL_DIR)

# Stage 1 Boot Sector (512 bytes)
$(BOOTSECT_BIN): $(BOOTSECT_SRC) | $(BUILD_DIR)
	@$(NASM) -f bin -o $@ $<

# Stage 2 Setup (A20, GDT, LMSW PM switch)
$(SETUP_BIN): $(SETUP_SRC) | $(BUILD_DIR)
	@$(NASM) -f bin -o $@ $<

# Ring 0 Protected Mode Kernel
$(KERNEL_BIN): $(KERNEL_DIR)/arch/i286/head.asm $(KERNEL_SRCS) | $(BUILD_DIR)
	@$(NASM) -f bin -I. -o $@ $<

# 1.44 MB Floppy Disk Image
$(FLOPPY_IMG): $(BOOTSECT_BIN) $(SETUP_BIN) $(KERNEL_BIN) | $(BUILD_DIR)
	@$(PYTHON) $(TOOLS_DIR)/mkfloppy.py $(BOOTSECT_BIN) $(SETUP_BIN) $(KERNEL_BIN) $@

# Disassembly of Kernel Machine Code
$(KERNEL_DIS): $(KERNEL_BIN)
	@$(NDISASM) -b 16 $< > $@

disasm: $(KERNEL_DIS)

# Static gatekeeper on disassembly listing
verify-disasm: $(KERNEL_DIS)
	@$(PYTHON) $(TOOLS_DIR)/check_286_opcodes.py --disasm $<

# Headless verification test via QEMU
test: all
	@$(PYTHON) $(TOOLS_DIR)/run_emulator.py --qemu

# Headless verification test via Bochs
test-bochs: all
	@$(PYTHON) $(TOOLS_DIR)/run_emulator.py --bochs

clean:
	@rm -rf $(BUILD_DIR)

help:
	@echo "Lin286 Build Targets:"
	@echo "  make             - Run gatekeeper, build floppy.img, and verify disassembly"
	@echo "  make test        - Build and run headless QEMU test with serial assertions"
	@echo "  make test-bochs  - Build and run headless Bochs test"
	@echo "  make gatekeeper  - Verify 80286 opcode compliance"
	@echo "  make clean       - Remove build artifacts"
