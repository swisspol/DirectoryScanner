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

#import <CommonCrypto/CommonDigest.h>
#import <sys/stat.h>
#import <sys/attr.h>
#import <dirent.h>
#import <libgen.h>

#import "DirectoryScanner.h"

#define __USE_GETATTRLIST__ 1

#pragma pack(push, 1)

typedef struct {
#if __USE_GETATTRLIST__
  uint32_t length;
#endif
  struct timespec created;
  struct timespec modified;
  uid_t uid;
  gid_t gid;
  u_int32_t mode;
  off_t size;
} Attributes;

#pragma pack(pop)

@interface Item ()
@property(nonatomic, readonly) mode_t mode;
@property(nonatomic, readonly) struct timespec created;
@property(nonatomic, readonly) struct timespec modified;
@end

#if __USE_GETATTRLIST__
static struct attrlist _attributeList = {0};
#endif

static inline BOOL _GetAttributes(const char* path, Attributes* attributes) {
#if __USE_GETATTRLIST__
  if (getattrlist(path, &_attributeList, attributes, sizeof(Attributes), FSOPT_NOFOLLOW) == 0)
#else
  struct stat info;
  if (lstat(path, &info) == 0)
#endif
  {
#if !__USE_GETATTRLIST__
    attributes->created.tv_sec = 0;
    attributes->created.tv_nsec = 0;
    attributes->modified = info.st_mtimespec;
    attributes->uid = info.st_uid;
    attributes->gid = info.st_gid;
    attributes->mode = info.st_mode;
    attributes->size = info.st_size;
#endif
    return YES;
  }
  return NO;
}

static inline NSDate* NSDateFromTimeSpec(const struct timespec* t) {
  return [NSDate dateWithTimeIntervalSince1970:((NSTimeInterval)t->tv_sec + (NSTimeInterval)t->tv_nsec / 1000000000.0)];
}

@implementation Item

@synthesize userID = _uid, groupID = _gid;

#if __USE_GETATTRLIST__

+ (void)initialize {
  if (self == [Item class]) {
    _attributeList.bitmapcount = ATTR_BIT_MAP_COUNT;
    _attributeList.commonattr = ATTR_CMN_CRTIME | ATTR_CMN_MODTIME | ATTR_CMN_OWNERID | ATTR_CMN_GRPID | ATTR_CMN_ACCESSMASK;
    _attributeList.fileattr = ATTR_FILE_DATALENGTH;
  }
}

#endif

- (id)initWithPath:(NSString*)path {
  if (![path isAbsolutePath]) {
    path = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:path];
  }
  const char* cPath = [[path stringByStandardizingPath] UTF8String];
  Attributes attributes;
  if (!_GetAttributes(cPath, &attributes)) {
    NSLog(@"Failed retrieving info for \"%s\" (%s)", cPath, strerror(errno));
    return nil;
  }
  return [self initWithParent:nil path:cPath base:strlen(cPath) name:basename((char*)cPath) attributes:&attributes];
}

- (id)initWithParent:(DirectoryItem*)parent path:(const char*)path base:(size_t)base name:(const char*)name attributes:(const Attributes*)attributes {
  if ((self = [super init])) {
    _parent = parent;
    _absolutePath = [[NSString alloc] initWithUTF8String:path];
    _relativePath = [[NSString alloc] initWithUTF8String:(parent ? &path[base + 1] : &path[base])];
    _name = [[NSString alloc] initWithUTF8String:name];
    _mode = attributes->mode;
    _uid = attributes->uid;
    _gid = attributes->gid;
    _created = attributes->created;
    _modified = attributes->modified;
  }
  return self;
}

- (short)posixPermissions {
  return (_mode & ALLPERMS);
}

- (NSDate*)creationDate {
  return NSDateFromTimeSpec(&_created);
}

- (NSDate*)modificationDate {
  return NSDateFromTimeSpec(&_modified);
}

- (BOOL)isDirectory {
  return (_mode & S_IFMT) == S_IFDIR;
}

- (BOOL)isFile {
  return (_mode & S_IFMT) == S_IFREG;
}

- (BOOL)isSymLink {
  return (_mode & S_IFMT) == S_IFLNK;
}

- (ComparisonResult)compareItem:(Item*)otherItem options:(ComparisonOptions)options {
  ComparisonResult result = 0;
  if (options & kComparisonOption_Ownership) {
    if ((_mode & ALLPERMS) != (otherItem->_mode & ALLPERMS)) {
      result |= kComparisonResult_Modified_Permissions;
    }
    if (_gid != otherItem->_gid) {
      result |= kComparisonResult_Modified_GroupID;
    }
    if (_uid != otherItem->_uid) {
      result |= kComparisonResult_Modified_UserID;
    }
  }
  if (options & kComparisonOption_Properties) {
    if ((_created.tv_sec != otherItem->_created.tv_sec) || (_created.tv_nsec != otherItem->_created.tv_nsec) ||
        (_modified.tv_sec != otherItem->_modified.tv_sec) || (_modified.tv_nsec != otherItem->_modified.tv_nsec)) {
      result |= kComparisonResult_Modified_FileDate;
    }
  }
  return result;
}

@end

@implementation FileItem

- (id)initWithParent:(DirectoryItem*)parent path:(const char*)path base:(size_t)base name:(const char*)name attributes:(const Attributes*)attributes {
  if ((self = [super initWithParent:parent path:path base:base name:name attributes:attributes])) {
    _size = attributes->size;
  }
  return self;
}

- (ComparisonResult)compareFile:(FileItem*)otherFile options:(ComparisonOptions)options {
  ComparisonResult result = [self compareItem:otherFile options:options];
  if (options & kComparisonOption_Properties) {
    if (_size != otherFile->_size) {
      result |= kComparisonResult_Modified_FileSize;
    }
  }
  if (options & kComparisonOption_Content) {
    if ([self isSymLink] && [otherFile isSymLink]) {
      if (_size == otherFile->_size) {
        
        char link[PATH_MAX + 1];
        ssize_t length = readlink([self.absolutePath UTF8String], link, PATH_MAX);
        if (length >= 0) {
          link[length] = 0;
        } else {
          NSLog(@"Failed reading symlink \"%@\" (%s)", self.absolutePath, strerror(errno));
        }
        
        char otherLink[PATH_MAX + 1];
        ssize_t otherLength = readlink([otherFile.absolutePath UTF8String], otherLink, PATH_MAX);
        if (otherLength >= 0) {
          otherLink[otherLength] = 0;
        } else {
          NSLog(@"Failed reading symlink \"%@\" (%s)", otherFile.absolutePath, strerror(errno));
        }
        
        if ((length < 0) || (otherLength < 0) || strcmp(link, otherLink)) {
          result |= kComparisonResult_Modified_FileContent;
        }
      } else {
        result |= kComparisonResult_Modified_FileContent;
      }
    } else if ([self isFile] && [otherFile isFile]) {
      if (_size == otherFile->_size) {
        
        unsigned char md5[16];
        NSData* data = [NSData dataWithContentsOfFile:self.absolutePath options:(NSDataReadingMappedIfSafe | NSDataReadingUncached) error:NULL];
        if (data) {
          CC_MD5(data.bytes, data.length, md5);
        } else {
          NSLog(@"Failed reading file \"%@\"", self.absolutePath);
        }
        
        unsigned char otherMd5[16];
        NSData* otherData = [NSData dataWithContentsOfFile:otherFile.absolutePath options:(NSDataReadingMappedIfSafe | NSDataReadingUncached) error:NULL];
        if (otherData) {
          CC_MD5(otherData.bytes, otherData.length, otherMd5);
        } else {
          NSLog(@"Failed reading file \"%@\"", otherFile.absolutePath);
        }
        
        if (!data || !otherData || memcmp(md5, otherMd5, 16)) {
          result |= kComparisonResult_Modified_FileContent;
        }
      } else {
        result |= kComparisonResult_Modified_FileContent;
      }
    } else {
      abort();  // Should not happen
    }
  }
  return result;
}

@end

@implementation DirectoryItem

- (id)initWithParent:(DirectoryItem*)parent path:(const char*)path base:(size_t)base name:(const char*)name attributes:(const Attributes*)attributes {
  if ((self = [super initWithParent:parent path:path base:base name:name attributes:attributes])) {
    _children = [[NSMutableArray alloc] init];
    
    DIR* directory;
    if ((directory = opendir(path))) {
      size_t pathLength = strlen(path);
      struct dirent storage;
      struct dirent* entry;
      while(1) {
        if ((readdir_r(directory, &storage, &entry) != 0) || !entry) {
          break;
        }
        if ((entry->d_name[0] == '.') && ((entry->d_name[1] == 0) || ((entry->d_name[1] == '.') && (entry->d_name[2] == 0)))) {
          continue;
        }
        char* buffer = malloc(pathLength + 1 + entry->d_namlen + 1);
        bcopy(path, buffer, pathLength);
        buffer[pathLength] = '/';
        bcopy(entry->d_name, &buffer[pathLength + 1], entry->d_namlen + 1);
        Attributes attributes;
        if (_GetAttributes(buffer, &attributes)) {
          Item* item = nil;
          switch (attributes.mode & S_IFMT) {
            
            case S_IFDIR:
              item = [[DirectoryItem alloc] initWithParent:self path:buffer base:base name:entry->d_name attributes:&attributes];
              break;
            
            case S_IFREG:
            case S_IFLNK:
              item = [[FileItem alloc] initWithParent:self path:buffer base:base name:entry->d_name attributes:&attributes];
              break;
            
          }
          if (item) {
            [(NSMutableArray*)_children addObject:item];
          }
        } else {
          NSLog(@"Failed retrieving info for \"%s\" (%s)", buffer, strerror(errno));
        }
        free(buffer);
      }
      closedir(directory);
      
      // opendir() enumeration order is not guaranteed depending on file systems so always sort children
      [(NSMutableArray*)_children sortUsingComparator:^NSComparisonResult(Item* item1, Item* item2) {
        return [item1.name caseInsensitiveCompare:item2.name];
      }];
    } else {
      NSLog(@"Failed opening directory \"%s\" (%s)", path, strerror(errno));
      return nil;
    }
  }
  return self;
}

- (void)enumerateChildrenRecursivelyUsingBlock:(void (^)(Item* item))block {
  for (Item* item in _children) {
    block(item);
    if ([item isDirectory]) {
      [(DirectoryItem*)item enumerateChildrenRecursivelyUsingBlock:block];
    }
  }
}

- (void)enumerateChildrenRecursivelyUsingEnterDirectoryBlock:(void (^)(DirectoryItem* directory))enterBlock
                                                   fileBlock:(void (^)(DirectoryItem* directory, FileItem* file))fileBlock
                                          exitDirectoryBlock:(void (^)(DirectoryItem* directory))exitBlock {
  if (enterBlock) {
    enterBlock(self);
  }
  for (Item* item in _children) {
    if ([item isDirectory]) {
      [(DirectoryItem*)item enumerateChildrenRecursivelyUsingEnterDirectoryBlock:enterBlock fileBlock:fileBlock exitDirectoryBlock:exitBlock];
    } else if (fileBlock) {
      fileBlock(self, (FileItem*)item);
    }
  }
  if (exitBlock) {
    exitBlock(self);
  }
}

- (void)compareDirectory:(DirectoryItem*)otherDirectory options:(ComparisonOptions)options withBlock:(void (^)(ComparisonResult result, Item* item, Item* otherItem))block {
  if (self.parent) {
    block([self compareItem:otherDirectory options:options], self, otherDirectory);
  }
  
  NSArray* otherChildren = otherDirectory.children;
  NSUInteger start = 0;
  NSUInteger end = otherChildren.count;
  for (Item* item in _children) {
    NSString* name = item.name;
    for (NSUInteger i = start; i < end; ++i) {
      Item* otherItem = (Item*)[otherChildren objectAtIndex:i];
      NSString* otherName = otherItem.name;
      NSComparisonResult result = [name caseInsensitiveCompare:otherName];
      if (result == NSOrderedSame) {
        if ([item isFile] && [otherItem isFile]) {
          block([(FileItem*)item compareFile:(FileItem*)otherItem options:options], item, otherItem);
        } else if ([item isSymLink] && [otherItem isSymLink]) {
          block([(FileItem*)item compareFile:(FileItem*)otherItem options:options], item, otherItem);
        } else if ([item isDirectory] && [otherItem isDirectory]) {
          @autoreleasepool {
            [(DirectoryItem*)item compareDirectory:(DirectoryItem*)otherItem options:options withBlock:block];
          }
        } else {
          block(kComparisonResult_Replaced, item, otherItem);
        }
        start = i + 1;
        break;
      } else if (result == NSOrderedAscending) {
        block(kComparisonResult_Removed, item, nil);
        start = i;
        break;
      } else {  // NSOrderedDescending
        block(kComparisonResult_Added, nil, otherItem);
      }
    }
  }
}

@end
