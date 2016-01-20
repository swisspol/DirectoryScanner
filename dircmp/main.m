/*
 Copyright (c) 2014-2016, Pierre-Olivier Latour
 All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 * Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 * The name of Pierre-Olivier Latour may not be used to endorse
 or promote products derived from this software without specific
 prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL PIERRE-OLIVIER LATOUR BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import <libgen.h>

#import "DirectoryScanner.h"

static BOOL _stop = NO;

static void _SignalHandler(int signal) {
  _stop = YES;
  printf("\n");
}

static inline void _PrintItem(Item* item, char c1, char c2, char c3, char c4, char c5, char c6, BOOL recursive, BOOL skipInvisible) {
  if (skipInvisible && [item.name hasPrefix:@"."]) {
    return;
  }
  if ([item isDirectory]) {
    fprintf(stdout, "[%c%c%c%c%c%c] %s/\n", c1, c2, c3, c4, c5, c6, [item.relativePath UTF8String]);
    if (recursive) {
      [(DirectoryItem*)item enumerateChildrenRecursivelyUsingBlock:^(Item* item) {
        if (skipInvisible && [item.name hasPrefix:@"."]) {
          return;
        }
        fprintf(stdout, "[%c%c%c%c%c%c] %s\n", c1, c2, c3, c4, c5, c6, [item.relativePath UTF8String]);
      }];
    }
  } else {
    fprintf(stdout, "[%c%c%c%c%c%c] %s\n", c1, c2, c3, c4, c5, c6, [item.relativePath UTF8String]);
  }
}

int main(int argc, const char* argv[]) {
  signal(SIGINT, _SignalHandler);
  @autoreleasepool {
    BOOL skipEqual = NO;
    BOOL skipInvisible = NO;
    BOOL showProgress = NO;
    ComparisonOptions options = 0;
    NSString* srcPath = nil;
    NSString* dstPath = nil;
    for (int i = 1; i < argc; ++i) {
      const char* arg = argv[i];
      if (arg[0] == '-') {
        const char* option = &arg[1];
        while (*option) {
          switch (*option) {
            case 'p': showProgress = YES; break;
            case 'e': skipEqual = YES; break;
            case 'i': skipInvisible = YES; break;
            case 'c': options |= kComparisonOption_FileContent; break;
          }
          ++option;
        }
      } else if (srcPath == nil) {
        srcPath = [NSString stringWithUTF8String:arg];
      } else if (dstPath == nil) {
        dstPath = [NSString stringWithUTF8String:arg];
      }
    }
    if (srcPath && dstPath) {
      BOOL success = [[DirectoryScanner sharedScanner] compareOldDirectoryAtPath:srcPath withNewDirectoryAtPath:dstPath options:options excludeBlock:^BOOL(DirectoryItem* directory) {
        if (showProgress) {
          fprintf(stdout, "%s\n", [directory.relativePath UTF8String]);
        }
        return _stop;
      } resultBlock:^(ComparisonResult result, Item* item, Item* otherItem, BOOL* stop) {
        if (result & kComparisonResult_ModifiedMask) {
          _PrintItem(item,
                     result & kComparisonResult_Modified_Permissions ? 'p' : '~',
                     result & kComparisonResult_Modified_GroupID ? 'g' : '~',
                     result & kComparisonResult_Modified_UserID ? 'u' : '~',
                     result & (kComparisonResult_Modified_CreationDate | kComparisonResult_Modified_ModificationDate) ? 'd' : '~',
                     result & (kComparisonResult_Modified_FileDataSize | kComparisonResult_Modified_FileResourceSize) ? 's' : '~',
                     result & (kComparisonResult_Modified_FileDataContent | kComparisonResult_Modified_FileResourceContent) ? 'c' : '~',
                     NO,
                     skipInvisible);
        } else if (result & kComparisonResult_Removed) {
          _PrintItem(item, '-', '-', '-', '-', '-', '-', YES, skipInvisible);
        } else if (result & kComparisonResult_Added) {
          _PrintItem(otherItem, '+', '+', '+', '+', '+', '+', YES, skipInvisible);
        } else if (result & kComparisonResult_Replaced) {
          _PrintItem(item, '-', '-', '-', '-', '-', '-', YES, skipInvisible);
          _PrintItem(otherItem, '+', '+', '+', '+', '+', '+', YES, skipInvisible);
        } else if (!skipEqual) {
          _PrintItem(item, '=', '=', '=', '=', '=', '=', YES, skipInvisible);
        }
        *stop = _stop;
      } errorBlock:^(NSError* error) {
        fprintf(stderr, "[%s] %s (%s)\n", [[error.userInfo objectForKey:NSFilePathErrorKey] UTF8String], [error.localizedDescription UTF8String], [error.localizedFailureReason UTF8String]);
      }];
      if (success) {
        return 0;
      }
    } else {
      fprintf(stdout, "Usage: %s [-p] [-e] [-i] [-c] sourceDirectory destinationDirectory\n", basename((char*)argv[0]));
    }
  }
  return 1;
}
