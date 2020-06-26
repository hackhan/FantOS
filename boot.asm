	;说明：FAT12引导扇区代码
	;作者：chent
	;日期：2020-06-25
	
;%define _BOOT_DEBUG_

%ifdef _BOOT_DEBUG_
	org 0100h	;编译成com文件，可在dos下调试
%else
	org 07c00h	;开机后BIOS把boot扇区加载到0x7c00处执行
%endif

;====================== <宏定义> ==========================
%ifdef _BOOT_DEBUG_
	BASE_OF_STACK	equ	0100h	;dos下栈基地址
%else
	BASE_OF_STACK	equ	07c00h	;栈基地址
%endif

	BASE_OF_LOADER	equ 0900h	;loader.bin被加载到的段地址
	OFFSET_OF_LOADER	equ 0100h	;loader.bin被加载到的偏移地址
	ROOT_DIR_SECTORS	equ 14	;根目录占用扇区数
	SECTOR_NO_OF_ROOT_DIRECTORY	equ 19	;根目录第一个扇区号
;====================== </宏定义> ==========================

	jmp short label_start
	nop	;FAT12引导扇区格式要求起始跳转指令占3个字节，上条指令2个字节，所以此处用一个无操作指令填充
	
	;FAT12磁盘头
	BS_OEMName	DB 'FantOS  '	;OEM String, 8字节
	BPB_BytsPerSec	DW 512	;每扇区字节数
	BPB_SecPerClus	DB 1	;每簇多少扇区
	BPB_RsvdSecCnt	DW 1	;Boot记录占用多少扇区
	BPB_NumFATs	DB 2	;FAT表数
	BPB_RootEntCnt	DW 224	;根目录文件数最大值
	BPB_TotSec16	DW 2880	;逻辑扇区总数
	BPB_Media	DB 0xF0	;媒体描述符
	BPB_FATSz16	DW 9	;每FAT扇区数
	BPB_SecPerTrk	DW 18	;每磁道扇区数
	BPB_NumHeads	DW 2	;磁头数(面数)
	BPB_HiddSec	DD 0	;隐藏扇区数
	BPB_TotSec32	DD 0	;如果 wTotalSectorCount 是 0 由这个值记录扇区数
	BS_DrvNum	DB 0	;中断 13 的驱动器号
	BS_Reserved1	DB 0	;未使用
	BS_BootSig	DB 29h	;扩展引导标记 (29h)
	BS_VolID	DD 0	;卷序列号
	BS_VolLab	DB 'FantOS V1.0'	;卷标, 11字节
	BS_FileSysType	DB 'FAT12   '	;文件系统类型, 8字节  

	
label_start:

	;初始化各段寄存器
	mov ax, cs
	mov ds, ax
	mov es, ax
	mov ss, ax
	mov sp, BASE_OF_STACK
	
	;复位软驱
	xor ah, ah
	xor dl, dl
	int 13h
	
	;在A盘根目录寻找loader.bin
	mov word [wsector_no], SECTOR_NO_OF_ROOT_DIRECTORY
	
label_search_in_root_dir_begin:

	;如果根目录所有扇区已经遍历完，则说明没有找到loader.bin
	cmp word [wroot_dir_size_for_loop], 0
	jz label_no_loaderbin
	
	;遍历扇区数-1
	dec word [wroot_dir_size_for_loop]
	
	;设置es:bx，扇区读取数据存放的位置
	mov ax, BASE_OF_LOADER
	mov es, ax
	mov bx, OFFSET_OF_LOADER
	
	mov ax, [wsector_no]	;ax <- 起始扇区编号
	mov cl, 1	;cl <- 要读取的扇区数
	call read_sector
	
	mov si, loader_file_name	;ds:si -> "LOADER  BIN"
	mov di, OFFSET_OF_LOADER	;es:di -> BASE_OF_LOADER:0100
	cld	;DF复位，向高地址增加
	mov dx, 10h	;512/32=16=10h, 表示每个扇区遍历的条目数

label_search_for_loaderbin:
	;如果dx已为0表示当前扇区已读完，跳转读取下一个扇区
	cmp dx, 0
	jz label_goto_next_sector_in_root_dir
	
	dec dx
	mov cx, 11	;"LOADER  BIN"占11字节长
	
label_cmp_filename:
	;如果11个字符都相等, 表示找到
	cmp cx, 0
	jz label_filename_found
	
	dec cx
	lodsb	;ds:si -> al
	cmp al, byte [es:di]
	jz label_go_on
	jmp label_different

label_go_on:
	inc di
	jmp label_cmp_filename
	
label_different:
	and di, 0FFE0h	;E0 -> 11100000, di &= E0可将di的低6位置零，使其指向本条目开头
	add di, 20h	;di += 32 指向下一个条目
	mov si, loader_file_name
	jmp label_search_for_loaderbin
	
label_goto_next_sector_in_root_dir:
	add word [wsector_no], 1
	jmp label_search_in_root_dir_begin
	
label_no_loaderbin:
	mov dh, 2
	call disp_str
%ifdef	_BOOT_DEBUG_
	;没有找到LOADER.BIN, 返回DOS
	mov ax, 4c00h
	int 21h
%else
	hlt
%endif

label_filename_found:
	and di, 0FFE0h	;将di置到当前条目开始
	add di, 01Ah
	mov cx, word [es:di] ;从偏移量1A处取得该文件首簇号
	
	;求loader.bin数据区起始扇区号
	push cx
	add cx, (1+2*9+ROOT_DIR_SECTORS-2)
	
	mov ax, BASE_OF_LOADER
	mov es, ax
	mov bx, OFFSET_OF_LOADER
	mov ax, cx

label_goon_loading_file:
	;每读一个扇区就在"Booting  "后追加一个 .
	push ax
	push bx
	mov ah, 0Eh
	mov al, '.'
	mov bl, 02h
	int 10h
	pop bx
	pop ax
	
	;读取一扇区
	mov cl, 1
	call read_sector
	
	pop ax	;ax <- loader.bin簇号
	call get_fat_entry
	cmp ax, 0FFFh	;判断该簇是否是文件最后一个簇
	jz label_file_loaded
	
	;求下一个簇号所对应的扇区
	push ax
	add ax, (1+2*9+ROOT_DIR_SECTORS-2)
	
	add bx, [BPB_BytsPerSec]	;bx+=512，用于读下一个扇区到此处
	jmp label_goon_loading_file

label_file_loaded:
	mov dh, 1	;"Ready.   "
	call disp_str
	
	;loader加载完毕，跳转到loader内开始执行
	jmp BASE_OF_LOADER:OFFSET_OF_LOADER

;======================= <变量定义> ==========================
wroot_dir_size_for_loop	dw	ROOT_DIR_SECTORS	;根目录占用扇区数
wsector_no	dw	0	;要读取的扇区号
bodd	db	0	;奇数/偶数

loader_file_name	db	"LOADER  BIN", 0	;loader.bin文件名
MESSAGE_LENGTH	equ	9
boot_message	db	"Booting  "	;9字节
message1	db	"Ready.   "	;9字节
message2	db	"No LOADER"	;9字节
;======================= </变量定义> ==========================



	;描述：显示字符串
	;入参：dh, 表示要显示哪个字符串
	;返回：
	;
	;备注：int10号中断
	;		AH	功能		调用参数
	;		13	显示字符串	ES:BP = 串地址 
	;						CX = 串长度 
	;						DH， DL = 起始行列 
	;						BH = 页号
	;						AL = 1，BL = 属性	光标跟随移动
disp_str:
	;计算要显示的字符串的地址
	mov al, MESSAGE_LENGTH
	mul dh
	add ax, boot_message
	
	;设置ES:BP串地址
	mov bp, ax
	mov ax, ds
	mov es, ax
	
	mov cx, MESSAGE_LENGTH	;串长度
	mov ax, 01301h	;AH=13, AL=01
	mov bx, 0002h	;页号为0（BH=0）黑底绿字
	mov dl, 0
	int 10h
	ret

	;描述：读取扇区
	;入参：
	;	AX, 起始扇区号
	;	CL, 读取扇区个数
	;返回：ES:BX
	;
	;备注：int 13h号中断
	;		寄存器						作用
	;		ah=02h al=要读取的扇区数	从磁盘将数据读入es:bx指向的缓冲区
	;		ch=柱面号 cl=起始扇区号
	;		dh=磁头号 dl=驱动器号
read_sector:
	push bp
	mov bp, sp
	sub sp, 2	;开辟两字节堆栈区保存要读取的扇区数
	
	mov byte [bp-2], cl
	push bx
	mov bl, [BPB_SecPerTrk]	;每磁道扇区数
	div bl
	inc ah
	mov cl, ah	;cl <- 起始扇区号
	mov dh, al
	shr al, 1
	mov ch, al	;ch <- 柱面号
	and dh, 1	;dh <- 磁头号
	pop bx
	mov dl, [BS_DrvNum]	;驱动器号，0表示A盘
.go_on_reading:
	mov ah, 2
	mov al, byte [bp-2]
	int 13h
	jc .go_on_reading
	
	add esp, 2
	pop bp
	ret
	
	;描述：根据簇号取FatEntry中的值
	;入参：ax, 扇区所代表的簇号
	;返回：ax, 簇号对应FatEntry所包含的值
get_fat_entry:
	push es
	push bx
	push ax
	
	;在BASE_OF_LOADER前开辟4k空间用于存放FAT表
	mov ax, BASE_OF_LOADER
	sub ax, 0100h	;4096=0x1000 0x1000>>4=0x100
	mov es, ax
	pop ax
	
	mov byte [bodd], 0
	
	;计算FatEntry在FAT表中字节偏移量，1 FatEntry = 1.5 Byte
	mov bx, 3
	mul bx
	mov bx, 2
	div bx	;该除法完成后，ax = FatEntry字节偏移量
	
	cmp dx, 0
	jz label_even
	mov byte [bodd], 1	;如果有余数，说明簇号是奇数

label_even:
	;根据FatEntry字节偏移量求扇区，ax / 512
	xor dx, dx
	mov bx, [BPB_BytsPerSec]
	div bx	;ax = FatEntry所在扇区相对于FAT表的扇区号
			;dx = FatEntry在扇区内偏移量
	
	push dx
	mov bx, 0
	add ax, [BPB_RsvdSecCnt]	;ax + 首个FAT表所在扇区号
	mov cl, 2	;因为FatEntry可能跨越两个扇区，所以此处读取两个扇区
	call read_sector
	
	pop dx
	add bx, dx
	mov ax, [es:bx]	;ax <- FatEntry
	
	cmp byte [bodd], 1
	jnz label_even_2
	shr ax, 4	;如果簇号是奇数，只需要取高12位，故右移4位
	
label_even_2:
	and ax, 0FFFh	;高4位清零
	
label_get_fat_enry_ok:
	pop	bx
	pop	es
	ret
	
	times 510-($-$$) db	0	;填充剩余空间
	db 0x55, 0xAA	;结束标志
