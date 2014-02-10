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
  kComparisonOption_FileContent = (1 << 0)
} ComparisonOptions;

typedef enum {
  kComparisonResult_Modified_Permissions = (1 << 0),
  kComparisonResult_Modified_GroupID = (1 << 1),
  kComparisonResult_Modified_UserID = (1 << 2),
  kComparisonResult_Modified_CreationDate = (1 << 3),
  kComparisonResult_Modified_ModificationDate = (1 << 4),
  kComparisonResult_Modified_FileDataSize = (1 << 5),
  kComparisonResult_Modified_FileResourceSize = (1 << 6),
  kComparisonResult_Modified_FileDataContent = (1 << 7),  // Requires "kComparisonOption_FileContent" option
  kComparisonResult_Modified_FileResourceContent = (1 << 8),  // Requires "kComparisonOption_FileContent" option
  kComparisonResult_Removed = (1 << 16),
  kComparisonResult_Added = (1 << 17),
  kComparisonResult_Replaced = (1 << 18)
} ComparisonResult;
#define kComparisonResult_ModifiedMask 0xFFFF

@class DirectoryItem;

@interface Item : NSObject
@property(weak, nonatomic, readonly) DirectoryItem* parent;
@property(nonatomic, readonly) NSString* absolutePath;
@property(nonatomic, readonly) NSString* relativePath;
@property(nonatomic, readonly) NSString* name;
@property(nonatomic, readonly) unsigned int userID;
@property(nonatomic, readonly) unsigned int groupID;
@property(nonatomic, readonly) short posixPermissions;
@property(nonatomic, readonly) NSDate* creationDate;
@property(nonatomic, readonly) NSDate* modificationDate;
- (id)initWithPath:(NSString*)path;
- (BOOL)isDirectory;
- (BOOL)isFile;
- (BOOL)isSymLink;
@end

@interface FileItem : Item
@property(nonatomic, readonly) unsigned long long dataSize;
@property(nonatomic, readonly) unsigned long long resourceSize;
@end

@interface DirectoryItem : Item
@property(nonatomic, readonly) NSArray* children;
- (void)enumerateChildrenRecursivelyUsingBlock:(void (^)(Item* item))block;
- (void)enumerateChildrenRecursivelyUsingEnterDirectoryBlock:(void (^)(DirectoryItem* directory))enterBlock
                                                   fileBlock:(void (^)(DirectoryItem* directory, FileItem* file))fileBlock
                                          exitDirectoryBlock:(void (^)(DirectoryItem* directory))exitBlock;
- (void)compareDirectory:(DirectoryItem*)otherDirectory options:(ComparisonOptions)options withBlock:(void (^)(ComparisonResult result, Item* item, Item* otherItem))block;
@end
