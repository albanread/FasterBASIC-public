# Traditional File I/O in FasterBASIC

*Classic BASIC file operations — just like Grandad used! Full support for INPUT, OUTPUT, APPEND, BINARY, and RANDOM file access modes.*

---

## Introduction

FasterBASIC brings back the **classic BASIC file I/O** that powered thousands of programs in the '80s and '90s. If you learned BASIC on a Commodore 64, Apple II, or wrote QuickBASIC programs on DOS, you'll feel right at home.

We support all the traditional file modes:
- **INPUT** - Read text files line by line
- **OUTPUT** - Create new files or overwrite existing ones
- **APPEND** - Add data to the end of existing files
- **BINARY** - Read and write raw bytes
- **RANDOM** - Database-style record access with fixed record lengths

Plus modern conveniences like flexible syntax, comprehensive error handling, and up to 256 files open simultaneously.

---

## Quick Start: Reading and Writing Text Files

### Writing a Text File

The simplest file operation — create a file and write some lines:

```basic
OPEN "greeting.txt" FOR OUTPUT AS #1
PRINT #1, "Hello, World!"
PRINT #1, "Welcome to FasterBASIC"
PRINT #1, "Enjoy traditional file I/O!"
CLOSE #1
```

**What's happening here:**
- `OPEN ... FOR OUTPUT` creates a new file (or overwrites if it exists)
- `AS #1` assigns it to file handle #1
- `PRINT #1, ...` writes each line to the file
- `CLOSE #1` closes the file when done

### Reading a Text File

Now read those lines back:

```basic
OPEN "greeting.txt" FOR INPUT AS #1
DIM line1 AS STRING
DIM line2 AS STRING
DIM line3 AS STRING
LINE INPUT #1, line1
LINE INPUT #1, line2
LINE INPUT #1, line3
CLOSE #1

PRINT line1  ' Prints: Hello, World!
PRINT line2  ' Prints: Welcome to FasterBASIC
PRINT line3  ' Prints: Enjoy traditional file I/O!
```

**Key points:**
- `OPEN ... FOR INPUT` opens an existing file for reading
- `LINE INPUT #1, variable` reads one complete line
- Always `CLOSE` your files when done

### Appending to a File

Add more data without erasing what's already there:

```basic
OPEN "greeting.txt" FOR APPEND AS #1
PRINT #1, "This line was appended!"
CLOSE #1
```

---

## File Modes Explained

FasterBASIC supports all five classic BASIC file modes:

### INPUT Mode

**Purpose:** Read text files  
**Syntax:** `OPEN "file.txt" FOR INPUT AS #1`  
**Aliases:** `OPEN "file.txt" FOR I AS #1`

- File must exist (Error 53 if not found)
- Read line-by-line with `LINE INPUT #1, variable$`
- Text mode (newline handling)
- Cannot write to INPUT files

### OUTPUT Mode

**Purpose:** Create or overwrite files  
**Syntax:** `OPEN "file.txt" FOR OUTPUT AS #1`  
**Aliases:** `OPEN "file.txt" FOR O AS #1`

- Creates new file or overwrites existing
- Write with `PRINT #1, data`
- Text mode
- Cannot read from OUTPUT files

### APPEND Mode

**Purpose:** Add to end of existing files  
**Syntax:** `OPEN "file.txt" FOR APPEND AS #1`  
**Aliases:** `OPEN "file.txt" FOR A AS #1`

- Creates file if it doesn't exist
- Writes always go to the end
- Cannot read from APPEND files
- Perfect for log files!

### BINARY Mode

**Purpose:** Read/write raw bytes  
**Syntax:** 
- `OPEN "data.bin" FOR BINARY INPUT AS #1`
- `OPEN "data.bin" FOR BINARY OUTPUT AS #1`

**Aliases:** `OPEN "data.bin" FOR B I AS #1`

- No text translation (raw bytes)
- Use with `INPUT$()`, `MKI$`, `MKD$`, etc.
- Essential for images, executables, custom formats

### RANDOM Mode

**Purpose:** Database-style record access  
**Syntax:** `OPEN "records.dat" FOR RANDOM AS #1`  
**With record length:** `OPEN "records.dat" FOR RANDOM 128 AS #1`  
**Aliases:** `OPEN "records.dat" FOR R 128 AS #1`

- Fixed-length records
- Direct access to any record
- Read/write without closing file
- Perfect for databases, indexed files

---

## Flexible Syntax

FasterBASIC accepts multiple syntax styles for compatibility:

### Long Form (Descriptive)
```basic
OPEN "data.txt" FOR INPUT AS #1
OPEN "output.txt" FOR OUTPUT AS #2
OPEN "data.bin" FOR BINARY OUTPUT AS #3
OPEN "records.dat" FOR RANDOM 128 AS #4
```

### Short Form (Single-Letter Aliases)
```basic
OPEN "data.txt" FOR I AS #1      ' Input
OPEN "output.txt" FOR O AS #2    ' Output
OPEN "data.bin" FOR B O AS #3    ' Binary Output
OPEN "records.dat" FOR R 128 AS #4  ' Random with record length
```

### Flexible Ordering
Both orders work:
```basic
OPEN "file.bin" FOR BINARY OUTPUT AS #1
OPEN "file.bin" FOR OUTPUT BINARY AS #1  ' Same thing!
```

### Dynamic Filenames and File Numbers
```basic
DIM filename AS STRING
filename = "data_" + DATE$ + ".txt"
OPEN filename FOR OUTPUT AS #1

DIM filenum AS INTEGER
filenum = 5
OPEN "data.txt" FOR OUTPUT AS #filenum
```

---

## Working with Binary Files

Binary mode is for raw data — images, executables, custom file formats, or when you need exact byte control.

### Writing Binary Data

```basic
REM Create a simple binary file format
OPEN "data.bin" FOR BINARY OUTPUT AS #1

REM Write a "magic number" header
DIM magic AS INTEGER
magic = 12345
PRINT #1, MKI$(magic)  ' Convert integer to 2-byte string

REM Write a version number
DIM version AS DOUBLE
version = 1.0
PRINT #1, MKD$(version)  ' Convert double to 8-byte string

REM Write some data
FOR i = 1 TO 10
    PRINT #1, MKI$(i * 100)
NEXT i

CLOSE #1
```

### Reading Binary Data

```basic
OPEN "data.bin" FOR BINARY INPUT AS #1

REM Read magic number
DIM magic_str AS STRING
magic_str = INPUT$(2, #1)  ' Read 2 bytes
DIM magic AS INTEGER
magic = CVI(magic_str)  ' Convert back to integer
PRINT "Magic: "; magic

REM Read version
DIM ver_str AS STRING
ver_str = INPUT$(8, #1)  ' Read 8 bytes
DIM version AS DOUBLE
version = CVD(ver_str)
PRINT "Version: "; version

CLOSE #1
```

### Binary Conversion Functions

| Function | Purpose | Bytes | Example |
|----------|---------|-------|---------|
| `MKI$(n)` | Integer → 2-byte string | 2 | `MKI$(1000)` |
| `MKD$(n)` | Double → 8-byte string | 8 | `MKD$(3.14159)` |
| `CVI(s$)` | 2-byte string → Integer | 2 | `CVI(data$)` |
| `CVD(s$)` | 8-byte string → Double | 8 | `CVD(data$)` |

---

## Random Access Files (Database-Style)

Random access files are like spreadsheets — organized into fixed-size records that you can access directly by number.

### Opening a Random File

```basic
REM Open with 100-byte records
OPEN "contacts.dat" FOR RANDOM 100 AS #1
```

### Why Use Random Access?

**Traditional sequential access:**
```
To read record #500:
- Read record 1
- Read record 2
- Read record 3
- ... (497 more reads)
- Read record 500
```

**Random access:**
```
To read record #500:
- Jump directly to record 500
- Read it
```

**Perfect for:**
- Address books
- Simple databases
- Indexed data
- High scores
- User profiles

### Example: Simple Phone Book

```basic
REM Define record structure (100 bytes total)
REM Name: 50 bytes, Phone: 20 bytes, City: 30 bytes

OPEN "phonebook.dat" FOR RANDOM 100 AS #1

REM Write record #1
DIM record AS STRING
record = ""
record = record + LEFT$("John Doe" + SPACE$(50), 50)
record = record + LEFT$("555-1234" + SPACE$(20), 20)
record = record + LEFT$("New York" + SPACE$(30), 30)
PRINT #1, record  ' Writes to current position

REM Write record #2
record = ""
record = record + LEFT$("Jane Smith" + SPACE$(50), 50)
record = record + LEFT$("555-5678" + SPACE$(20), 20)
record = record + LEFT$("Boston" + SPACE$(30), 30)
PRINT #1, record

REM Read record #1 directly
SEEK #1, 1  ' Position to start of record 1
DIM data AS STRING
data = INPUT$(100, #1)
DIM name AS STRING
name = TRIM$(LEFT$(data, 50))
PRINT "Name: "; name

CLOSE #1
```

---

## File Position Functions

Track where you are in a file:

### LOC() - Current Position

Returns current file position (in 128-byte blocks for sequential files):

```basic
OPEN "data.txt" FOR OUTPUT AS #1
PRINT #1, "Some data"
DIM pos AS INTEGER
pos = LOC(1)
PRINT "Position: "; pos
CLOSE #1
```

### LOF() - File Length

Returns the total length of the file in bytes:

```basic
OPEN "data.txt" FOR INPUT AS #1
DIM size AS INTEGER
size = LOF(1)
PRINT "File size: "; size; " bytes"
CLOSE #1
```

### SEEK - Move File Pointer

Jump to a specific byte position (1-based):

```basic
OPEN "data.bin" FOR BINARY INPUT AS #1
SEEK #1, 100  ' Jump to byte 100
DIM data AS STRING
data = INPUT$(10, #1)  ' Read 10 bytes from position 100
CLOSE #1
```

### INPUT$() - Read N Bytes

Read an exact number of bytes as a string:

```basic
OPEN "data.bin" FOR BINARY INPUT AS #1
DIM header AS STRING
header = INPUT$(16, #1)  ' Read 16-byte header
CLOSE #1
```

---

## Error Handling

File operations can fail for many reasons. FasterBASIC provides comprehensive error codes for robust programs.

### Error Codes

| Code | Name | Condition |
|------|------|-----------|
| 53 | File Not Found | Opening non-existent file for INPUT |
| 64 | Bad File Number | Invalid file number (< 0 or > 255) |
| 75 | Permission Denied | Can't write to read-only file |
| 56 | File Not Open | Operation on closed file |
| 5 | Illegal Call | Invalid parameters (e.g., string too short for CVI) |
| 62 | Input Past End | Reading beyond end of file |
| 61 | Disk Full | No space left on device |

### Basic Error Checking

```basic
TRY
    OPEN "data.txt" FOR INPUT AS #1
    DIM data AS STRING
    LINE INPUT #1, data
    CLOSE #1
    PRINT "Data: "; data
CATCH
    IF ERR = 53 THEN
        PRINT "Error: File not found!"
    ELSE IF ERR = 75 THEN
        PRINT "Error: Permission denied!"
    ELSE
        PRINT "Error "; ERR; " at line "; ERL()
    END IF
END TRY
```

### Multiple Error Handlers

```basic
TRY
    OPEN "missing.txt" FOR INPUT AS #1
CATCH 53
    PRINT "File not found - creating it..."
    OPEN "missing.txt" FOR OUTPUT AS #1
    PRINT #1, "Default data"
    CLOSE #1
CATCH
    PRINT "Unexpected error: "; ERR
END TRY
```

### Robust File Reading

```basic
FUNCTION ReadConfigFile(filename AS STRING) AS INTEGER
    DIM success AS INTEGER
    success = 0
    
    TRY
        OPEN filename FOR INPUT AS #1
        
        TRY
            DIM line AS STRING
            WHILE NOT EOF(1)
                LINE INPUT #1, line
                REM Process configuration line...
            WEND
            success = 1
        CATCH
            PRINT "Error reading file: "; ERR
        END TRY
        
        CLOSE #1
        
    CATCH 53
        PRINT "Config file not found, using defaults"
        success = CreateDefaultConfig(filename)
    CATCH 75
        PRINT "Permission denied: "; filename
    CATCH
        PRINT "Error opening file: "; ERR
    END TRY
    
    RETURN success
END FUNCTION
```

---

## Multiple Files

You can have up to **256 files** open simultaneously:

```basic
REM Open multiple files
OPEN "input1.txt" FOR INPUT AS #1
OPEN "input2.txt" FOR INPUT AS #2
OPEN "output.txt" FOR OUTPUT AS #3

REM Read from multiple sources
DIM line1 AS STRING
DIM line2 AS STRING
LINE INPUT #1, line1
LINE INPUT #2, line2

REM Merge into output
PRINT #3, "From file 1: "; line1
PRINT #3, "From file 2: "; line2

REM Close all
CLOSE #1
CLOSE #2
CLOSE #3
```

### File Number Management

```basic
REM Use constants for file numbers
CONST LOG_FILE = 1
CONST DATA_FILE = 2
CONST CONFIG_FILE = 3

OPEN "app.log" FOR APPEND AS #LOG_FILE
OPEN "data.txt" FOR INPUT AS #DATA_FILE
OPEN "config.ini" FOR INPUT AS #CONFIG_FILE

PRINT #LOG_FILE, "Application started"

CLOSE #LOG_FILE
CLOSE #DATA_FILE
CLOSE #CONFIG_FILE
```

---

## Real-World Examples

### Log File

```basic
SUB WriteLog(message AS STRING)
    TRY
        OPEN "app.log" FOR APPEND AS #99
        PRINT #99, DATE$; " "; TIME$; " - "; message
        CLOSE #99
    CATCH
        PRINT "Warning: Could not write to log file"
    END TRY
END SUB

WriteLog("Application started")
WriteLog("Processing data...")
WriteLog("Application finished")
```

### Configuration File

```basic
REM Write config
OPEN "game.cfg" FOR OUTPUT AS #1
PRINT #1, "PlayerName=Hero"
PRINT #1, "Difficulty=5"
PRINT #1, "SoundVolume=80"
CLOSE #1

REM Read config
OPEN "game.cfg" FOR INPUT AS #1
DIM line AS STRING
DIM player AS STRING
DIM difficulty AS INTEGER
DIM volume AS INTEGER

WHILE NOT EOF(1)
    LINE INPUT #1, line
    IF LEFT$(line, 11) = "PlayerName=" THEN
        player = MID$(line, 12)
    ELSE IF LEFT$(line, 11) = "Difficulty=" THEN
        difficulty = VAL(MID$(line, 12))
    ELSE IF LEFT$(line, 12) = "SoundVolume=" THEN
        volume = VAL(MID$(line, 13))
    END IF
WEND
CLOSE #1

PRINT "Player: "; player
PRINT "Difficulty: "; difficulty
PRINT "Volume: "; volume
```

### High Score Table (Random Access)

```basic
TYPE ScoreEntry
    PlayerName AS STRING
    Score AS INTEGER
    Date AS STRING
END TYPE

REM Initialize high score file (10 entries, 100 bytes each)
OPEN "scores.dat" FOR RANDOM 100 AS #1

SUB SaveScore(entry AS ScoreEntry, position AS INTEGER)
    SEEK #1, (position - 1) * 100 + 1
    DIM record AS STRING
    record = LEFT$(entry.PlayerName + SPACE$(50), 50)
    record = record + MKI$(entry.Score)
    record = record + LEFT$(entry.Date + SPACE$(48), 48)
    PRINT #1, record
END SUB

FUNCTION LoadScore(position AS INTEGER) AS ScoreEntry
    DIM entry AS ScoreEntry
    SEEK #1, (position - 1) * 100 + 1
    DIM record AS STRING
    record = INPUT$(100, #1)
    entry.PlayerName = TRIM$(LEFT$(record, 50))
    entry.Score = CVI(MID$(record, 51, 2))
    entry.Date = TRIM$(MID$(record, 53, 48))
    RETURN entry
END FUNCTION

REM Usage
DIM newScore AS ScoreEntry
newScore.PlayerName = "ACE"
newScore.Score = 99999
newScore.Date = DATE$
SaveScore(newScore, 1)

DIM topScore AS ScoreEntry
topScore = LoadScore(1)
PRINT "Top player: "; topScore.PlayerName
PRINT "Score: "; topScore.Score
PRINT "Date: "; topScore.Date

CLOSE #1
```

---

## Best Practices

### 1. Always Close Files

```basic
REM Good - explicit close
OPEN "data.txt" FOR OUTPUT AS #1
PRINT #1, "Data"
CLOSE #1

REM Better - use TRY to ensure closing
TRY
    OPEN "data.txt" FOR OUTPUT AS #1
    PRINT #1, "Data"
    IF error_condition THEN THROW 99
FINALLY
    CLOSE #1  ' Always executes
END TRY
```

### 2. Check for Errors

```basic
REM Don't assume files exist
TRY
    OPEN "input.txt" FOR INPUT AS #1
CATCH 53
    PRINT "Creating default input file..."
    OPEN "input.txt" FOR OUTPUT AS #1
    PRINT #1, "Default data"
    CLOSE #1
END TRY
```

### 3. Use Meaningful File Numbers

```basic
REM Bad
OPEN "file1.txt" FOR INPUT AS #1
OPEN "file2.txt" FOR INPUT AS #2

REM Good
CONST INPUT_FILE = 1
CONST OUTPUT_FILE = 2
OPEN "file1.txt" FOR INPUT AS #INPUT_FILE
OPEN "file2.txt" FOR OUTPUT AS #OUTPUT_FILE
```

### 4. Document Binary File Formats

```basic
REM Custom binary format:
REM Bytes 0-1:   Magic number (0x1234)
REM Bytes 2-9:   Version (double)
REM Bytes 10-11: Record count (integer)
REM Bytes 12+:   Records (variable)

OPEN "data.bin" FOR BINARY OUTPUT AS #1
PRINT #1, MKI$(&h1234)      ' Magic
PRINT #1, MKD$(1.0)         ' Version
PRINT #1, MKI$(record_count) ' Count
```

### 5. Buffer Large Writes

```basic
REM Build string in memory, write once
DIM buffer AS STRING
buffer = ""
FOR i = 1 TO 1000
    buffer = buffer + "Line " + STR$(i) + CHR$(10)
NEXT i
OPEN "output.txt" FOR OUTPUT AS #1
PRINT #1, buffer
CLOSE #1
```

---

## Compatibility with QuickBASIC

FasterBASIC's file I/O is designed to be **compatible with QuickBASIC 4.5 and QBasic**. Most QB programs will work with minimal or no changes:

### What Works Identically
- ✅ OPEN, CLOSE, LINE INPUT, PRINT #
- ✅ All file modes (INPUT, OUTPUT, APPEND, BINARY, RANDOM)
- ✅ Error codes match QB standard
- ✅ MKI$, MKD$, CVI, CVD functions
- ✅ LOC(), LOF() functions
- ✅ INPUT$() function

### FasterBASIC Extensions
- ✅ Flexible syntax (BINARY OUTPUT or OUTPUT BINARY)
- ✅ Single-letter mode aliases (I, O, A, B, R)
- ✅ Better error messages
- ✅ Up to 256 simultaneous files (QB: 15)
- ✅ Expression-based filenames and file numbers

### Runtime Ready, Parser/Codegen Pending
- 🔧 FIELD/LSET/RSET statements - Runtime functions complete, parser integration needed
- 🔧 PUT #/GET # with record numbers - Runtime functions complete, parser integration needed
- ⏸️ LINE INPUT from console with prompt - Not yet implemented

**Note:** The core runtime functions for FIELD buffer management, LSET/RSET operations, and PUT/GET record access are fully implemented in `binary_io.zig`. Only the parser statement handlers and code generation are needed to make these available in BASIC programs.

---

## Summary

FasterBASIC brings back the **classic file I/O** that made BASIC so practical:

**Text Files:**
- `OPEN "file.txt" FOR INPUT` - Read
- `OPEN "file.txt" FOR OUTPUT` - Write
- `OPEN "file.txt" FOR APPEND` - Add to end
- `LINE INPUT #1, variable$` - Read lines

**Binary Files:**
- `OPEN "file.bin" FOR BINARY INPUT/OUTPUT`
- `INPUT$(n, #1)` - Read n bytes
- `MKI$`/`CVI` - Convert numbers ↔ bytes

**Random Access:**
- `OPEN "file.dat" FOR RANDOM 128` - Fixed records
- `LOC()`, `LOF()`, `SEEK` - Navigate
- Perfect for databases

**Error Handling:**
- Error 53: File Not Found
- Error 64: Bad File Number
- Error 75: Permission Denied
- TRY/CATCH for robust code

**Up to 256 files open simultaneously. QuickBASIC compatible. Modern extensions included.**

It's the I/O Grandad used — now faster, safer, and more flexible!

---

## Further Reading

For more details, see the comprehensive documentation:

- **[FILE_IO_ENHANCEMENTS_SUMMARY.md](../FILE_IO_ENHANCEMENTS_SUMMARY.md)** - Complete OPEN statement guide
- **[BINARY_RANDOM_FILE_IO.md](../BINARY_RANDOM_FILE_IO.md)** - Binary and random access deep dive
- **[FILE_ERROR_HANDLING_SUMMARY.md](../FILE_ERROR_HANDLING_SUMMARY.md)** - Error codes and patterns
- **[LINE_INPUT_FIX_SUMMARY.md](../LINE_INPUT_FIX_SUMMARY.md)** - Technical implementation details

---

*Happy coding! May your files never corrupt and your handles never leak. 📁*