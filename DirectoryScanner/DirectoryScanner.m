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

static inline NSTimeInterval NSTimeIntervalFromTimeSpec(const struct timespec* t) {
  return (NSTimeInterval)t->tv_sec + (NSTimeInterval)t->tv_nsec / 1000000000.0 - NSTimeIntervalSince1970;
}

@implementation Item

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
    _absolutePath = strdup(path);
    _relativePath = (parent ? &_absolutePath[base + 1] : &_absolutePath[base]);
    _name = strdup(name);
    _mode = attributes->mode;
    _uid = attributes->uid;
    _gid = attributes->gid;
  }
  return self;
}

- (void)dealloc {
  if (_absolutePath) {
    free((void*)_absolutePath);
  }
  if (_name) {
    free((void*)_name);
  }
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

- (ComparisonResult)compareOwnership:(Item*)otherItem {
  ComparisonResult result = 0;
  if ((_mode & ALLPERMS) != (otherItem->_mode & ALLPERMS)) {
    result |= kComparisonResult_Modified_Permissions;
  }
  if (_gid != otherItem->_gid) {
    result |= kComparisonResult_Modified_GroupID;
  }
  if (_uid != otherItem->_uid) {
    result |= kComparisonResult_Modified_UserID;
  }
  return result;
}

@end

@implementation FileItem

- (id)initWithParent:(DirectoryItem*)parent path:(const char*)path base:(size_t)base name:(const char*)name attributes:(const Attributes*)attributes {
  if ((self = [super initWithParent:parent path:path base:base name:name attributes:attributes])) {
    _size = attributes->size;
    _created = NSTimeIntervalFromTimeSpec(&attributes->created);
    _modified = NSTimeIntervalFromTimeSpec(&attributes->modified);
  }
  return self;
}

- (ComparisonResult)compareFile:(FileItem*)otherFile options:(ComparisonOptions)options {
  ComparisonResult result = 0;
  if (options & kComparisonOption_Ownership) {
    result |= [self compareOwnership:otherFile];
  }
  if (options & kComparisonOption_Properties) {
    if (_size != otherFile->_size) {
      result |= kComparisonResult_Modified_FileSize;
    }
    if ((_created != otherFile->_created) || (_modified != otherFile->_modified)) {
      result |= kComparisonResult_Modified_FileDate;
    }
  }
  if (options & kComparisonOption_Content) {
    if ([self isSymLink] && [otherFile isSymLink]) {
      if (_size == otherFile->_size) {
        
        char link[PATH_MAX + 1];
        ssize_t length = readlink(self.absolutePath, link, PATH_MAX);
        if (length >= 0) {
          link[length] = 0;
        } else {
          NSLog(@"Failed reading symlink \"%s\" (%s)", self.absolutePath, strerror(errno));
        }
        
        char otherLink[PATH_MAX + 1];
        ssize_t otherLength = readlink(otherFile.absolutePath, otherLink, PATH_MAX);
        if (otherLength >= 0) {
          otherLink[otherLength] = 0;
        } else {
          NSLog(@"Failed reading symlink \"%s\" (%s)", otherFile.absolutePath, strerror(errno));
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
        NSData* data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:self.absolutePath] options:(NSDataReadingMappedIfSafe | NSDataReadingUncached) error:NULL];
        if (data) {
          CC_MD5(data.bytes, data.length, md5);
        } else {
          NSLog(@"Failed reading file \"%s\"", self.absolutePath);
        }
        
        unsigned char otherMd5[16];
        NSData* otherData = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:otherFile.absolutePath] options:(NSDataReadingMappedIfSafe | NSDataReadingUncached) error:NULL];
        if (otherData) {
          CC_MD5(otherData.bytes, otherData.length, otherMd5);
        } else {
          NSLog(@"Failed reading file \"%s\"", otherFile.absolutePath);
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
        int result = strcmp(item1.name, item2.name);
        return (result > 0 ? NSOrderedDescending : (result < 0 ? NSOrderedAscending : NSOrderedSame));
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
    ComparisonResult result = 0;
    if (options & kComparisonOption_Ownership) {
      result |= [self compareOwnership:otherDirectory];
    }
    block(result, self, otherDirectory);
  }
  
  NSArray* otherChildren = otherDirectory.children;
  NSUInteger start = 0;
  NSUInteger end = otherChildren.count;
  for (Item* item in _children) {
    const char* name = item.name;
    for (NSUInteger i = start; i < end; ++i) {
      Item* otherItem = (Item*)[otherChildren objectAtIndex:i];
      const char* otherName = otherItem.name;
      int result = strcmp(name, otherName);
      if (result == 0) {
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
      } else if (result < 0) {
        block(kComparisonResult_Removed, item, nil);
        start = i;
        break;
      } else {
        block(kComparisonResult_Added, nil, otherItem);
      }
    }
  }
}

@end
