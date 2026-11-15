#import "YTMUZipExtractor.h"
#import <zlib.h>
#import <sys/stat.h>

#pragma pack(push, 1)
typedef struct {
    uint32_t signature;       // 0x04034b50
    uint16_t versionNeeded;
    uint16_t flags;
    uint16_t compression;    // 0 = store, 8 = deflate
    uint16_t modTime;
    uint16_t modDate;
    uint32_t crc32;
    uint32_t compressedSize;
    uint32_t uncompressedSize;
    uint16_t filenameLength;
    uint16_t extraLength;
} YTMUZipLocalHeader;
#pragma pack(pop)

#define YTMU_ZIP_BUF_SIZE 65536

@implementation YTMUZipExtractor

+ (BOOL)unzipFileAtPath:(NSString *)zipPath toDestination:(NSString *)destDir error:(NSError **)outError {
    FILE *f = fopen([zipPath fileSystemRepresentation], "rb");
    if (!f) {
        if (outError) {
            *outError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{NSLocalizedDescriptionKey: @"Failed to open zip file"}];
        }
        return NO;
    }

    [[NSFileManager defaultManager] createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:nil];

    uint8_t inBuf[YTMU_ZIP_BUF_SIZE];
    uint8_t outBuf[YTMU_ZIP_BUF_SIZE];

    BOOL ok = YES;
    while (!feof(f)) {
        YTMUZipLocalHeader hdr;
        if (fread(&hdr, 1, sizeof(hdr), f) < sizeof(hdr)) {
            break;
        }
        if (hdr.signature != 0x04034b50) {
            // Reached Central Directory or end of entries
            break;
        }

        // Read filename
        char nameBuf[1024];
        uint16_t nameLen = hdr.filenameLength;
        if (nameLen >= sizeof(nameBuf)) nameLen = sizeof(nameBuf) - 1;
        if (fread(nameBuf, 1, nameLen, f) < nameLen) {
            ok = NO; break;
        }
        nameBuf[nameLen] = '\0';

        // Skip remaining filename if longer than buffer, plus extra field
        if (hdr.filenameLength > nameLen) {
            fseek(f, hdr.filenameLength - nameLen, SEEK_CUR);
        }
        if (hdr.extraLength > 0) {
            fseek(f, hdr.extraLength, SEEK_CUR);
        }

        NSString *relPath = [NSString stringWithUTF8String:nameBuf];
        if (!relPath.length) continue;

        NSString *targetPath = [destDir stringByAppendingPathComponent:relPath];

        // Directory entry
        if (nameBuf[nameLen - 1] == '/') {
            [[NSFileManager defaultManager] createDirectoryAtPath:targetPath withIntermediateDirectories:YES attributes:nil error:nil];
            continue;
        }

        // Ensure parent directory exists
        NSString *parentDir = [targetPath stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:parentDir withIntermediateDirectories:YES attributes:nil error:nil];

        FILE *outF = fopen([targetPath fileSystemRepresentation], "wb");
        if (!outF) {
            // Skip compressed bytes if we couldn't open target
            fseek(f, hdr.compressedSize, SEEK_CUR);
            continue;
        }

        if (hdr.compression == 0) {
            // Stored
            uint32_t remaining = hdr.uncompressedSize;
            while (remaining > 0) {
                size_t toRead = (remaining < YTMU_ZIP_BUF_SIZE) ? remaining : YTMU_ZIP_BUF_SIZE;
                size_t readBytes = fread(inBuf, 1, toRead, f);
                if (readBytes == 0) break;
                fwrite(inBuf, 1, readBytes, outF);
                remaining -= readBytes;
            }
        } else if (hdr.compression == 8) {
            // Deflate
            z_stream strm;
            memset(&strm, 0, sizeof(strm));
            // -MAX_WBITS specifies raw DEFLATE stream without zlib header
            if (inflateInit2(&strm, -MAX_WBITS) != Z_OK) {
                fclose(outF);
                fseek(f, hdr.compressedSize, SEEK_CUR);
                continue;
            }

            uint32_t compRemaining = hdr.compressedSize;
            int ret = Z_OK;
            while (compRemaining > 0 && ret != Z_STREAM_END) {
                size_t toRead = (compRemaining < YTMU_ZIP_BUF_SIZE) ? compRemaining : YTMU_ZIP_BUF_SIZE;
                size_t readBytes = fread(inBuf, 1, toRead, f);
                if (readBytes == 0) break;
                compRemaining -= readBytes;

                strm.avail_in = (uInt)readBytes;
                strm.next_in = inBuf;

                do {
                    strm.avail_out = (uInt)YTMU_ZIP_BUF_SIZE;
                    strm.next_out = outBuf;
                    ret = inflate(&strm, Z_NO_FLUSH);
                    if (ret == Z_STREAM_ERROR || ret == Z_DATA_ERROR || ret == Z_MEM_ERROR) {
                        break;
                    }
                    size_t have = YTMU_ZIP_BUF_SIZE - strm.avail_out;
                    if (have > 0) {
                        fwrite(outBuf, 1, have, outF);
                    }
                } while (strm.avail_out == 0 && ret != Z_STREAM_END);
            }
            inflateEnd(&strm);
        } else {
            // Unsupported compression
            fseek(f, hdr.compressedSize, SEEK_CUR);
        }

        fclose(outF);
    }

    fclose(f);
    return ok;
}

@end
