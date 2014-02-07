/*
 Copyright (c) 2014, Pierre-Olivier Latour
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

#import <Foundation/Foundation.h>

typedef enum {
  kComparisonOption_Ownership = (1 << 0),
  kComparisonOption_Properties = (1 << 1),
  kComparisonOption_Content = (1 << 2),
  kComparisonOption_All = (kComparisonOption_Ownership | kComparisonOption_Properties | kComparisonOption_Content)
} ComparisonOptions;

typedef enum {
  kComparisonResult_Modified_Permissions = (1 << 0),  // Requires "kComparisonOption_Ownership" option
  kComparisonResult_Modified_GroupID = (1 << 1),  // Requires "kComparisonOption_Ownership" option
  kComparisonResult_Modified_UserID = (1 << 2),  // Requires "kComparisonOption_Ownership" option
  kComparisonResult_Modified_FileSize = (1 << 3),  // Requires "kComparisonOption_Properties" option
  kComparisonResult_Modified_FileDate = (1 << 4),  // Requires "kComparisonOption_Properties" option
  kComparisonResult_Modified_FileContent = (1 << 5),  // Requires "kComparisonOption_Content" option
  kComparisonResult_Removed = (1 << 16),
  kComparisonResult_Added = (1 << 17),
  kComparisonResult_Replaced = (1 << 18)
} ComparisonResult;
#define kComparisonResult_ModifiedMask 0xF

@class DirectoryItem;

@interface Item : NSObject
@property(weak, nonatomic, readonly) DirectoryItem* parent;
@property(nonatomic, readonly) const char* absolutePath;
@property(nonatomic, readonly) const char* relativePath;
@property(nonatomic, readonly) const char* name;
@property(nonatomic, readonly) mode_t mode;
@property(nonatomic, readonly) uid_t uid;
@property(nonatomic, readonly) gid_t gid;
- (id)initWithPath:(NSString*)path;
- (BOOL)isDirectory;
- (BOOL)isFile;
- (BOOL)isSymLink;
@end

@interface FileItem : Item
@property(nonatomic, readonly) off_t size;
@property(nonatomic, readonly) NSTimeInterval created;
@property(nonatomic, readonly) NSTimeInterval modified;
@end

@interface DirectoryItem : Item
@property(nonatomic, readonly) NSArray* children;
- (void)enumerateChildrenRecursivelyUsingBlock:(void (^)(Item* item))block;
- (void)enumerateChildrenRecursivelyUsingEnterDirectoryBlock:(void (^)(DirectoryItem* directory))enterBlock
                                                   fileBlock:(void (^)(DirectoryItem* directory, FileItem* file))fileBlock
                                          exitDirectoryBlock:(void (^)(DirectoryItem* directory))exitBlock;
- (void)compareDirectory:(DirectoryItem*)otherDirectory options:(ComparisonOptions)options withBlock:(void (^)(ComparisonResult result, Item* item, Item* otherItem))block;
@end
