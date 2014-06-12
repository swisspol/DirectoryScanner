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

#define kFileCompareIOBufferSize (256 * 1024)  // Optimal size seems to be 64 KB for SSDs but 256 KB for HDDs
#define kResourceForkPath @"..namedfork/rsrc"

#define CALL_ERROR_BLOCK(__MESSAGE__, __PATH__) \
  do { \
    if (errorBlock) { \
      NSError* error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ \
        NSFilePathErrorKey: __PATH__, \
        NSLocalizedDescriptionKey: __MESSAGE__, \
        NSLocalizedFailureReasonErrorKey: [NSString stringWithUTF8String:strerror(errno)] \
      }]; \
      errorBlock(error); \
    } \
  } while (0)

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
  off_t dataSize;
  off_t rsrcSize;
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

static inline const char* _NSStringToPath(NSString* s) {
  return [[NSFileManager defaultManager] fileSystemRepresentationWithPath:s];
}

static inline NSString* _NSStringFromPath(const char* s) {
  return [[NSFileManager defaultManager] stringWithFileSystemRepresentation:s length:strlen(s)];
}

static inline NSComparisonResult _CompareStrings(NSString* s1, NSString* s2) {
  return [s1 compare:s2 options:(NSCaseInsensitiveSearch | NSNumericSearch | NSWidthInsensitiveSearch)];  // Same as -localizedStandardCompare: minus NSForcedOrderingSearch
}

static inline BOOL _GetAttributes(const char* path, Attributes* attributes) {
#if __USE_GETATTRLIST__
  if (getattrlist(path, &_attributeList, attributes, sizeof(Attributes), FSOPT_NOFOLLOW) == 0)
#else
  struct stat info;
  if (lstat(path, &info) == 0)
#endif
  {
#if !__USE_GETATTRLIST__
    attributes->created.tv_sec = 0;  // N/A
    attributes->created.tv_nsec = 0;  // N/A
    attributes->modified = info.st_mtimespec;
    attributes->uid = info.st_uid;
    attributes->gid = info.st_gid;
    attributes->mode = info.st_mode;
    attributes->dataSize = info.st_size;
    attributes->rsrcSize = 0;  // N/A
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

- (id)initWithParent:(DirectoryItem*)parent path:(const char*)path base:(size_t)base name:(const char*)name attributes:(const Attributes*)attributes {
  if ((self = [super init])) {
    _parent = parent;
    _absolutePath = _NSStringFromPath(path);
    _relativePath = _NSStringFromPath(parent ? &path[base + 1] : &path[base]);
    _name = _NSStringFromPath(name);
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

- (ComparisonResult)compareItem:(Item*)otherItem withOptions:(ComparisonOptions)options {
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
  if ((_created.tv_sec != otherItem->_created.tv_sec) || (_created.tv_nsec != otherItem->_created.tv_nsec)) {
    result |= kComparisonResult_Modified_CreationDate;
  }
  if ((_modified.tv_sec != otherItem->_modified.tv_sec) || (_modified.tv_nsec != otherItem->_modified.tv_nsec)) {
    result |= kComparisonResult_Modified_ModificationDate;
  }
  return result;
}

@end

@implementation FileItem

- (id)initWithParent:(DirectoryItem*)parent path:(const char*)path base:(size_t)base name:(const char*)name attributes:(const Attributes*)attributes {
  if ((self = [super initWithParent:parent path:path base:base name:name attributes:attributes])) {
    _dataSize = attributes->dataSize;
    _resourceSize = attributes->rsrcSize;
  }
  return self;
}

static BOOL _CompareSymLinks(NSString* path1, NSString* path2, void(^errorBlock)(NSError*)) {
  char link1[PATH_MAX + 1];
  ssize_t length1 = readlink(_NSStringToPath(path1), link1, PATH_MAX);
  if (length1 >= 0) {
    link1[length1] = 0;
  } else {
    CALL_ERROR_BLOCK(@"Failed reading symlink", path1);
  }
  
  char link2[PATH_MAX + 1];
  ssize_t length2 = readlink(_NSStringToPath(path2), link2, PATH_MAX);
  if (length2 >= 0) {
    link2[length2] = 0;
  } else {
    CALL_ERROR_BLOCK(@"Failed reading symlink", path2);
  }
  
  if ((length1 < 0) || (length2 < 0) || strcmp(link1, link2)) {
    return NO;
  }
  return YES;
}

static BOOL _CompareFiles(NSString* path1, NSString* path2, void(^errorBlock)(NSError*)) {
  BOOL success = NO;
  int fd1 = open(_NSStringToPath(path1), O_RDONLY | O_NOFOLLOW);
  if (fd1 > 0) {
    int fd2 = open(_NSStringToPath(path2), O_RDONLY | O_NOFOLLOW);
    if (fd2 > 0) {
      
      if (fcntl(fd1, F_NOCACHE, 1) < 0) {
        CALL_ERROR_BLOCK(@"Failed enabling uncached read for file", path1);
      }
      if (fcntl(fd1, F_RDAHEAD, 1) < 0) {
        CALL_ERROR_BLOCK(@"Failed enabling read-ahead for file", path1);
      }
      void* buffer1 = malloc(kFileCompareIOBufferSize);
      
      if (fcntl(fd2, F_NOCACHE, 1) < 0) {
        CALL_ERROR_BLOCK(@"Failed enabling uncached read for file", path2);
      }
      if (fcntl(fd2, F_RDAHEAD, 1) < 0) {
        CALL_ERROR_BLOCK(@"Failed enabling read-ahead for file", path2);
      }
      void* buffer2 = malloc(kFileCompareIOBufferSize);
      
      while (1) {
        ssize_t size1 = read(fd1, buffer1, kFileCompareIOBufferSize);
        ssize_t size2 = read(fd2, buffer2, kFileCompareIOBufferSize);
        if ((size1 < 0) || (size2 < 0) || (size1 != size2)) {
          break;
        }
        if (memcmp(buffer1, buffer2, size1)) {
          break;
        }
        if (size1 < kFileCompareIOBufferSize) {
          success = YES;
          break;
        }
      }
      
      free(buffer1);
      free(buffer2);
      close(fd2);
    } else {
      CALL_ERROR_BLOCK(@"Failed opening file for reading", path2);
    }
    close(fd1);
  } else {
    CALL_ERROR_BLOCK(@"Failed opening file for reading", path1);
  }
  return success;
}

- (ComparisonResult)compareFile:(FileItem*)otherFile
                    withOptions:(ComparisonOptions)options
                     errorBlock:(void (^)(NSError* error))errorBlock {
  ComparisonResult result = [self compareItem:otherFile withOptions:options];
  if (_dataSize != otherFile->_dataSize) {
    result |= kComparisonResult_Modified_FileDataSize;
  }
  if (_resourceSize != otherFile->_resourceSize) {
    result |= kComparisonResult_Modified_FileResourceSize;
  }
  if (options & kComparisonOption_FileContent) {
    if ([self isSymLink] && [otherFile isSymLink]) {
      if ((_dataSize != otherFile->_dataSize) || !_CompareSymLinks(self.absolutePath, otherFile.absolutePath, errorBlock)) {
        result |= kComparisonResult_Modified_FileDataContent;
      }
    } else if ([self isFile] && [otherFile isFile]) {
      if ((_dataSize != otherFile->_dataSize) || ((_dataSize > 0) && !_CompareFiles(self.absolutePath, otherFile.absolutePath, errorBlock))) {
        result |= kComparisonResult_Modified_FileDataContent;
      }
      if ((_resourceSize != otherFile->_resourceSize) || ((_resourceSize > 0) && !_CompareFiles([self.absolutePath stringByAppendingPathComponent:kResourceForkPath], [otherFile.absolutePath stringByAppendingPathComponent:kResourceForkPath], errorBlock))) {
        result |= kComparisonResult_Modified_FileResourceContent;
      }
    } else {
      abort();  // Should not happen
    }
  }
  return result;
}

@end

@implementation DirectoryItem

- (id)initWithParent:(DirectoryItem*)parent path:(const char*)path base:(size_t)base name:(const char*)name attributes:(const Attributes*)attributes
        excludeBlock:(BOOL (^)(DirectoryItem* directory))excludeBlock
          errorBlock:(void (^)(NSError* error))errorBlock {
  if ((self = [super initWithParent:parent path:path base:base name:name attributes:attributes])) {
    if (excludeBlock && excludeBlock(self)) {
      return nil;
    }
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
              item = [[DirectoryItem alloc] initWithParent:self path:buffer base:base name:entry->d_name attributes:&attributes excludeBlock:excludeBlock errorBlock:errorBlock];
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
          CALL_ERROR_BLOCK(@"Failed retrieving file system info", _NSStringFromPath(buffer));
        }
        free(buffer);
      }
      closedir(directory);
      
      [(NSMutableArray*)_children sortUsingComparator:^NSComparisonResult(Item* item1, Item* item2) {
        return _CompareStrings(item1.name, item2.name);
      }];
    } else {
      CALL_ERROR_BLOCK(@"Failed opening directory", _NSStringFromPath(path));
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

- (BOOL)compareDirectory:(DirectoryItem*)otherDirectory
             withOptions:(ComparisonOptions)options
             resultBlock:(void (^)(ComparisonResult result, Item* item, Item* otherItem, BOOL* stop))block
              errorBlock:(void (^)(NSError* error))errorBlock {
  BOOL stop = NO;
  if (self.parent) {
    block([self compareItem:otherDirectory withOptions:options], self, otherDirectory, &stop);
  }
  
  NSArray* otherChildren = otherDirectory.children;
  NSUInteger start = 0;
  NSUInteger end = otherChildren.count;
  for (Item* item in _children) {
    if (stop) {
      return NO;
    }
    NSString* name = item.name;
    for (NSUInteger i = start; i < end; ++i) {
      Item* otherItem = (Item*)[otherChildren objectAtIndex:i];
      NSString* otherName = otherItem.name;
      NSComparisonResult result = _CompareStrings(name, otherName);
      if (result == NSOrderedSame) {
        if ([item isFile] && [otherItem isFile]) {
          block([(FileItem*)item compareFile:(FileItem*)otherItem withOptions:options errorBlock:errorBlock], item, otherItem, &stop);
        } else if ([item isSymLink] && [otherItem isSymLink]) {
          block([(FileItem*)item compareFile:(FileItem*)otherItem withOptions:options errorBlock:errorBlock], item, otherItem, &stop);
        } else if ([item isDirectory] && [otherItem isDirectory]) {
          @autoreleasepool {
            stop = ![(DirectoryItem*)item compareDirectory:(DirectoryItem*)otherItem withOptions:options resultBlock:block errorBlock:errorBlock];
          }
        } else {
          block(kComparisonResult_Replaced, item, otherItem, &stop);
        }
        start = i + 1;
        break;
      } else if (result == NSOrderedAscending) {
        block(kComparisonResult_Removed, item, nil, &stop);
        start = i;
        break;
      } else {  // NSOrderedDescending
        block(kComparisonResult_Added, nil, otherItem, &stop);
        if (stop) {
          break;
        }
      }
    }
  }
  for (NSUInteger i = start; i < end; ++i) {
    Item* otherItem = (Item*)[otherChildren objectAtIndex:i];
    block(kComparisonResult_Added, nil, otherItem, &stop);
    if (stop) {
      return NO;
    }
  }
  
  return YES;
}

@end

@implementation DirectoryScanner

+ (DirectoryScanner*)sharedScanner {
  static DirectoryScanner* scanner = nil;
  static dispatch_once_t token = 0;
  dispatch_once(&token, ^{
#if __USE_GETATTRLIST__
    _attributeList.bitmapcount = ATTR_BIT_MAP_COUNT;
    _attributeList.commonattr = ATTR_CMN_CRTIME | ATTR_CMN_MODTIME | ATTR_CMN_OWNERID | ATTR_CMN_GRPID | ATTR_CMN_ACCESSMASK;
    _attributeList.fileattr = ATTR_FILE_DATALENGTH | ATTR_FILE_RSRCLENGTH;
#endif
    scanner = [[DirectoryScanner alloc] init];
  });
  return scanner;
}

static const char* _GetCPathAndAttributes(NSString* path, Attributes* attributes, void(^errorBlock)(NSError*)) {
  if (![path isAbsolutePath]) {
    path = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:path];
  }
  const char* cPath = _NSStringToPath([path stringByStandardizingPath]);
  if (!_GetAttributes(cPath, attributes)) {
    CALL_ERROR_BLOCK(@"Failed retrieving file system info", _NSStringFromPath(cPath));
    return NULL;
  }
  return cPath;
}

- (DirectoryItem*)scanDirectoryAtPath:(NSString*)path
                     withExcludeBlock:(BOOL (^)(DirectoryItem* directory))excludeBlock
                           errorBlock:(void (^)(NSError* error))errorBlock {
  Attributes attributes;
  const char* cPath = _GetCPathAndAttributes(path, &attributes, errorBlock);
  if (!cPath) {
    return nil;
  }
  return [[DirectoryItem alloc] initWithParent:nil path:cPath base:strlen(cPath) name:basename((char*)cPath) attributes:&attributes excludeBlock:excludeBlock errorBlock:errorBlock];
}

- (BOOL)compareOldDirectory:(DirectoryItem*)oldDirectory
           withNewDirectory:(DirectoryItem*)newDirectory
                    options:(ComparisonOptions)options
                resultBlock:(void (^)(ComparisonResult result, Item* item, Item* otherItem, BOOL* stop))block
                 errorBlock:(void (^)(NSError* error))errorBlock {
  return [oldDirectory compareDirectory:newDirectory withOptions:options resultBlock:block errorBlock:errorBlock];
}

- (BOOL)compareOldDirectoryAtPath:(NSString*)oldPath
           withNewDirectoryAtPath:(NSString*)newPath
                          options:(ComparisonOptions)options
                     excludeBlock:(BOOL (^)(DirectoryItem* directory))excludeBlock
                      resultBlock:(void (^)(ComparisonResult result, Item* item, Item* otherItem, BOOL* stop))resultBlock
                       errorBlock:(void (^)(NSError* error))errorBlock {
  Attributes oldAttributes;
  const char* oldCPath = _GetCPathAndAttributes(oldPath, &oldAttributes, errorBlock);
  Attributes newAttributes;
  const char* newCPath = _GetCPathAndAttributes(newPath, &newAttributes, errorBlock);
  if (!oldCPath || !newCPath) {
    return NO;
  }
  
  BOOL differentDevices = NO;
  struct stat oldInfo;
  struct stat newInfo;
  if ((lstat(oldCPath, &oldInfo) == 0) && (lstat(newCPath, &newInfo) == 0) && (oldInfo.st_dev != newInfo.st_dev)) {
    differentDevices = YES;
  }
  
  __block DirectoryItem* oldDirectory = nil;
  __block DirectoryItem* newDirectory = nil;
  if (differentDevices) {
    dispatch_semaphore_t oldSemaphore = dispatch_semaphore_create(0);
    dispatch_semaphore_t newSemaphore = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      @autoreleasepool {
        oldDirectory = [[DirectoryItem alloc] initWithParent:nil path:oldCPath base:strlen(oldCPath) name:basename((char*)oldCPath) attributes:&oldAttributes excludeBlock:excludeBlock errorBlock:errorBlock];
      }
      dispatch_semaphore_signal(oldSemaphore);
    });
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      @autoreleasepool {
        newDirectory = [[DirectoryItem alloc] initWithParent:nil path:newCPath base:strlen(newCPath) name:basename((char*)newCPath) attributes:&newAttributes excludeBlock:excludeBlock errorBlock:errorBlock];
      }
      dispatch_semaphore_signal(newSemaphore);
    });
    dispatch_semaphore_wait(newSemaphore, DISPATCH_TIME_FOREVER);
    dispatch_release(newSemaphore);
    dispatch_semaphore_wait(oldSemaphore, DISPATCH_TIME_FOREVER);
    dispatch_release(oldSemaphore);
  } else {
    oldDirectory = [[DirectoryItem alloc] initWithParent:nil path:oldCPath base:strlen(oldCPath) name:basename((char*)oldCPath) attributes:&oldAttributes excludeBlock:excludeBlock errorBlock:errorBlock];
    newDirectory = [[DirectoryItem alloc] initWithParent:nil path:newCPath base:strlen(newCPath) name:basename((char*)newCPath) attributes:&newAttributes excludeBlock:excludeBlock errorBlock:errorBlock];
  }
  if (!oldDirectory || !newDirectory) {
    return NO;
  }
  
  return [self compareOldDirectory:oldDirectory withNewDirectory:newDirectory options:options resultBlock:resultBlock errorBlock:errorBlock];
}

@end
