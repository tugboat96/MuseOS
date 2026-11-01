/*
 * MuseOS - Copy-on-Write (CoW) Block Allocator Inner Loop
 * Architecture: AMD64 (x86_64)
 * File: kernel/asm/cow_allocator/block_scan.S
 *
 * Provides high-performance bitmap scanning routines utilizing AMD64 bit-manipulation
 * instructions (tzcnt, blsr, btr, bt) to locate free blocks for the CoW storage engine.
 *
 * Calling Convention: System V AMD64 ABI
 *   rdi = argument 1
 *   rsi = argument 2
 *   rdx = argument 3
 *   rax = return value
 */

.intel_syntax noprefix

.global cow_find_free_block
.global cow_scan_contiguous_blocks
.global cow_mark_block_allocated

.text

/*
 * cow_find_free_block(const uint64_t *bitmap, uint64_t num_words) -> int64_t
 *
 * Searches bitmap for the first set bit (1 = free block, 0 = allocated block).
 * Uses tzcnt (Trailing Zero Count) for zero-overhead bit scanning.
 *
 * Inputs:
 *   rdi: pointer to array of uint64_t bitmap words
 *   rsi: number of uint64_t words in the bitmap
 *
 * Returns:
 *   rax: zero-based index of first free block, or -1 (0xFFFFFFFFFFFFFFFF) if full
 */
cow_find_free_block:
    push    rbx
    push    r12
    
    xor     rcx, rcx                # Word index counter = 0
    
.Lscan_word_loop:
    cmp     rcx, rsi                # Check if we've processed all words
    jge     .Lno_free_block
    
    mov     rax, [rdi + rcx*8]      # Load 64-bit bitmap word
    test    rax, rax                # Check if word has any set bits (free blocks)
    jnz     .Lfound_free_bit
    
    inc     rcx                     # Advance to next 64-bit word
    jmp     .Lscan_word_loop

.Lfound_free_bit:
    /* Use AMD64 tzcnt instruction to find trailing zeros (index of first 1 bit) */
    tzcnt   rbx, rax                # rbx = count of trailing zeros in rax
    
    /* Calculate absolute block index: (word_index * 64) + bit_offset */
    shl     rcx, 6                  # rcx = word_index * 64
    add     rcx, rbx                # rcx = total block index
    mov     rax, rcx                # Return block index in rax
    
    pop     r12
    pop     rbx
    ret

.Lno_free_block:
    mov     rax, -1                 # Return -1 indicating no free block found
    pop     r12
    pop     rbx
    ret

/*
 * cow_scan_contiguous_blocks(const uint64_t *bitmap, uint64_t num_words, uint64_t count) -> int64_t
 *
 * Scans the bitmap for a contiguous run of 'count' free bits.
 *
 * Inputs:
 *   rdi: pointer to bitmap words
 *   rsi: total words in bitmap
 *   rdx: number of contiguous free blocks required
 *
 * Returns:
 *   rax: starting block index of contiguous run, or -1 if unavailable
 */
cow_scan_contiguous_blocks:
    push    rbx
    push    r12
    push    r13
    push    r14

    cmp     rdx, 0
    jle     .Lscan_contig_failed

    shl     rsi, 6                  # rsi = total bits in bitmap (num_words * 64)
    xor     rax, rax                # Current bit index = 0
    xor     rbx, rbx                # Contiguous free count = 0
    mov     r12, -1                 # Candidate start index = -1

.Lscan_bit_loop:
    cmp     rax, rsi
    jge     .Lscan_contig_failed

    /* Test bit at index 'rax' in bitmap array 'rdi' */
    mov     r13, rax
    shr     r13, 6                  # r13 = word index
    mov     r14, [rdi + r13*8]      # Load word
    mov     rcx, rax
    and     rcx, 63                 # rcx = bit offset within word
    bt      r14, rcx                # Bit Test instruction: copies bit to Carry Flag
    jnc     .Lbit_is_allocated

.Lbit_is_free:
    cmp     rbx, 0
    jne     .Lincrement_contig
    mov     r12, rax                # Set candidate start index

.Lincrement_contig:
    inc     rbx
    cmp     rbx, rdx
    je      .Lfound_contiguous
    inc     rax
    jmp     .Lscan_bit_loop

.Lbit_is_allocated:
    xor     rbx, rbx                # Reset contiguous count
    mov     r12, -1                 # Reset candidate start
    inc     rax
    jmp     .Lscan_bit_loop

.Lfound_contiguous:
    mov     rax, r12                # Return candidate starting block index
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.Lscan_contig_failed:
    mov     rax, -1
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

/*
 * cow_mark_block_allocated(uint64_t *bitmap, uint64_t block_index) -> void
 *
 * Uses Bit Reset (btr) instructions to clear a block state in the allocation bitmap.
 *
 * Inputs:
 *   rdi: pointer to bitmap words
 *   rsi: zero-based block index to mark as allocated (clears bit to 0)
 */
cow_mark_block_allocated:
    mov     rax, rsi
    shr     rax, 6                  # Word index = block_index / 64
    mov     rcx, rsi
    and     rcx, 63                 # Bit offset = block_index % 64
    
    /* Clear bit at offset in bitmap word */
    btr     qword ptr [rdi + rax*8], rcx
    ret
