# Android平台特有的ClassLoader

1. PathClassLoader 可以加载apk中的代码

2. DexClassLoader 可以加载任意位置的代码

3. InMemoryDexClassLoader 加载内存中的代码。

他们都继承 BaseDexClassLoader

# BaseDexClassLoader

除非使用InMemoryDexClassLoader， 一般正常使用的话都是会调用BaseDexClassLoader这个构造函数

libcore/dalvik/src/main/java/dalvik/system/BaseDexClassLoader.java

```java
public BaseDexClassLoader(String dexPath,
            String librarySearchPath, ClassLoader parent, ClassLoader[] sharedLibraryLoaders,
            boolean isTrusted) {
        super(parent);
        // Setup shared libraries before creating the path list. ART relies on the class loader
        // hierarchy being finalized before loading dex files.
        this.sharedLibraryLoaders = sharedLibraryLoaders == null
                ? null
                : Arrays.copyOf(sharedLibraryLoaders, sharedLibraryLoaders.length);
        this.pathList = new DexPathList(this, dexPath, librarySearchPath, null, isTrusted);

        reportClassLoaderChain();
}
```

这里创建了一个pathList


当我们去查找一个类的时候，会采用双亲委托机制去查找，也就是说先到父类加载器中去查找，如果没有找到，那么当前的这个class loader就要负责加载类。

这时候需要重写 findClass 函数

```java
 @Override
    protected Class<?> findClass(String name) throws ClassNotFoundException {
        // First, check whether the class is present in our shared libraries.
        if (sharedLibraryLoaders != null) {
            for (ClassLoader loader : sharedLibraryLoaders) {
                try {
                    return loader.loadClass(name);
                } catch (ClassNotFoundException ignored) {
                }
            }
        }
        // Check whether the class in question is present in the dexPath that
        // this classloader operates on.
        List<Throwable> suppressedExceptions = new ArrayList<Throwable>();
        Class c = pathList.findClass(name, suppressedExceptions);
        if (c == null) {
            ClassNotFoundException cnfe = new ClassNotFoundException(
                    "Didn't find class \"" + name + "\" on path: " + pathList);
            for (Throwable t : suppressedExceptions) {
                cnfe.addSuppressed(t);
            }
            throw cnfe;
        }
        return c;
    }
```

我们可以看到findClass函数其实就是把请求转发给了PathList。我们看下PathList的源码。

PathList的构造函数

```java
DexPathList(ClassLoader definingContext, String dexPath,
            String librarySearchPath, File optimizedDirectory, boolean isTrusted) {
        // ...

        this.definingContext = definingContext;

        ArrayList<IOException> suppressedExceptions = new ArrayList<IOException>();
        // save dexPath for BaseDexClassLoader
        this.dexElements = makeDexElements(splitDexPath(dexPath), optimizedDirectory,
                                           suppressedExceptions, definingContext, isTrusted);

        // Native libraries may exist in both the system and
        // application library paths, and we use this search order:
        //
        //   1. This class loader's library path for application libraries (librarySearchPath):
        //   1.1. Native library directories
        //   1.2. Path to libraries in apk-files
        //   2. The VM's library path from the system property for system libraries
        //      also known as java.library.path
        //
        // This order was reversed prior to Gingerbread; see http://b/2933456.
        this.nativeLibraryDirectories = splitPaths(librarySearchPath, false);
        this.systemNativeLibraryDirectories =
                splitPaths(System.getProperty("java.library.path"), true);
        this.nativeLibraryPathElements = makePathElements(getAllNativeLibraryDirectories());

        if (suppressedExceptions.size() > 0) {
            this.dexElementsSuppressedExceptions =
                suppressedExceptions.toArray(new IOException[suppressedExceptions.size()]);
        } else {
            dexElementsSuppressedExceptions = null;
        }
    }
```

这行代码首先创建了 dexElements 列表。并且给出了so查找路径。so查找路径不是本次重点。先看如何创建dex列表。

```java
 private static Element[] makeDexElements(List<File> files, File optimizedDirectory,
            List<IOException> suppressedExceptions, ClassLoader loader, boolean isTrusted) {
      Element[] elements = new Element[files.size()];
      int elementsPos = 0;
      /*
       * Open all files and load the (direct or contained) dex files up front.
       */
      for (File file : files) {
          if (file.isDirectory()) {
              // We support directories for looking up resources. Looking up resources in
              // directories is useful for running libcore tests.
              elements[elementsPos++] = new Element(file);
          } else if (file.isFile()) {
              String name = file.getName();

              DexFile dex = null;
              if (name.endsWith(DEX_SUFFIX)) {
                  // Raw dex file (not inside a zip/jar).
                  try {
                      dex = loadDexFile(file, optimizedDirectory, loader, elements);
                      if (dex != null) {
                          elements[elementsPos++] = new Element(dex, null);
                      }
                  } catch (IOException suppressed) {
                      System.logE("Unable to load dex file: " + file, suppressed);
                      suppressedExceptions.add(suppressed);
                  }
              } else {
                  try {
                      dex = loadDexFile(file, optimizedDirectory, loader, elements);
                  } catch (IOException suppressed) {
                      /*
                       * IOException might get thrown "legitimately" by the DexFile constructor if
                       * the zip file turns out to be resource-only (that is, no classes.dex file
                       * in it).
                       * Let dex == null and hang on to the exception to add to the tea-leaves for
                       * when findClass returns null.
                       */
                      suppressedExceptions.add(suppressed);
                  }

                  if (dex == null) {
                      elements[elementsPos++] = new Element(file);
                  } else {
                      elements[elementsPos++] = new Element(dex, file);
                  }
              }
              if (dex != null && isTrusted) {
                dex.setTrusted();
              }
          } else {
              System.logW("ClassLoader referenced unknown path: " + file);
          }
      }
      if (elementsPos != elements.length) {
          elements = Arrays.copyOf(elements, elementsPos);
      }
      return elements;
    }
```

核心都是调用loadDexFile创建DexFile然后填充数组。

```java
    @UnsupportedAppUsage
    private static DexFile loadDexFile(File file, File optimizedDirectory, ClassLoader loader,
                                       Element[] elements)
            throws IOException {
        if (optimizedDirectory == null) {
            return new DexFile(file, loader, elements);
        } else {
            String optimizedPath = optimizedPathFor(file, optimizedDirectory);
            return DexFile.loadDex(file.getPath(), optimizedPath, 0, loader, elements);
        }
    }

```

如果当前的优化路径是空的，那么直接返回dex file否则调用DexFile.loadDex去加载代码。

```java
    @UnsupportedAppUsage
    static DexFile loadDex(String sourcePathName, String outputPathName,
        int flags, ClassLoader loader, DexPathList.Element[] elements) throws IOException {
        return new DexFile(sourcePathName, outputPathName, flags, loader, elements);
    }
```

其实无论优化路径空不空，其实都是调用的这个构造函数

```java
 DexFile(String fileName, ClassLoader loader, DexPathList.Element[] elements)
            throws IOException {
        mCookie = openDexFile(fileName, null, 0, loader, elements);
        mInternalCookie = mCookie;
        mFileName = fileName;
        //System.out.println("DEX FILE cookie is " + mCookie + " fileName=" + fileName);
    }
```

核心在于openDexFile

```java
 private static Object openDexFile(String sourceName, String outputName, int flags,
            ClassLoader loader, DexPathList.Element[] elements) throws IOException {
        // Use absolute paths to enable the use of relative paths when testing on host.
        return openDexFileNative(new File(sourceName).getAbsolutePath(),
                                 (outputName == null)
                                     ? null
                                     : new File(outputName).getAbsolutePath(),
                                 flags,
                                 loader,
                                 elements);
    }
```

这个方法把调用转发到了native层 

art/runtime/native/dalvik_system_DexFile.cc

```cpp
static jobject DexFile_openDexFileNative(JNIEnv* env,
                                         jclass,
                                         jstring javaSourceName,
                                         jstring javaOutputName ATTRIBUTE_UNUSED,
                                         jint flags ATTRIBUTE_UNUSED,
                                         jobject class_loader,
                                         jobjectArray dex_elements) {
  ScopedUtfChars sourceName(env, javaSourceName);
  if (sourceName.c_str() == nullptr) {
    return nullptr;
  }

  std::vector<std::string> error_msgs;
  const OatFile* oat_file = nullptr;
  std::vector<std::unique_ptr<const DexFile>> dex_files =
      Runtime::Current()->GetOatFileManager().OpenDexFilesFromOat(sourceName.c_str(),
                                                                  class_loader,
                                                                  dex_elements,
                                                                  /*out*/ &oat_file,
                                                                  /*out*/ &error_msgs);
  return CreateCookieFromOatFileManagerResult(env, dex_files, oat_file, error_msgs);
}
```

openDexFileNative 会调用OatFileManager的OpenDexFilesFromOat函数去打开dex file， CreateCookieFromOatFileManagerResult

```cpp
std::vector<std::unique_ptr<const DexFile>> OatFileManager::OpenDexFilesFromOat(
    const char* dex_location,
    jobject class_loader,
    jobjectArray dex_elements,
    const OatFile** out_oat_file,
    std::vector<std::string>* error_msgs) {
  // ...

  // Verify we aren't holding the mutator lock, which could starve GC when
  // hitting the disk.
  Thread* const self = Thread::Current();
  Locks::mutator_lock_->AssertNotHeld(self);
  Runtime* const runtime = Runtime::Current();

  std::vector<std::unique_ptr<const DexFile>> dex_files;

  // If the class_loader is null there's not much we can do. This happens if a dex files is loaded
  // directly with DexFile APIs instead of using class loaders.
  if (class_loader == nullptr) {
    LOG(WARNING) << "Opening an oat file without a class loader. "
                 << "Are you using the deprecated DexFile APIs?";
  } else {
    std::unique_ptr<ClassLoaderContext> context(
        ClassLoaderContext::CreateContextForClassLoader(class_loader, dex_elements));

    OatFileAssistant oat_file_assistant(dex_location,
                                        kRuntimeISA,
                                        runtime->GetOatFilesExecutable(),
                                        only_use_system_oat_files_);

    // Get the oat file on disk.
    std::unique_ptr<const OatFile> oat_file(oat_file_assistant.GetBestOatFile().release());
    VLOG(oat) << "OatFileAssistant(" << dex_location << ").GetBestOatFile()="
              << reinterpret_cast<uintptr_t>(oat_file.get())
              << " (executable=" << (oat_file != nullptr ? oat_file->IsExecutable() : false) << ")";

    const OatFile* source_oat_file = nullptr;
    std::string error_msg;
    bool is_special_shared_library = false;
    bool class_loader_context_matches = false;
    if (oat_file != nullptr &&
        context != nullptr &&
        ClassLoaderContextMatches(oat_file.get(),
                                  context.get(),
                                  /*out*/ &is_special_shared_library,
                                  /*out*/ &error_msg)) {
      class_loader_context_matches = true;
      // Load the dex files from the oat file.
      bool added_image_space = false;
      if (oat_file->IsExecutable()) {
        ScopedTrace app_image_timing("AppImage:Loading");

        // We need to throw away the image space if we are debuggable but the oat-file source of the
        // image is not otherwise we might get classes with inlined methods or other such things.
        std::unique_ptr<gc::space::ImageSpace> image_space;
        if (!is_special_shared_library && ShouldLoadAppImage(oat_file.get())) {
          image_space = oat_file_assistant.OpenImageSpace(oat_file.get());
        }
        if (image_space != nullptr) {
          ScopedObjectAccess soa(self);
          StackHandleScope<1> hs(self);
          Handle<mirror::ClassLoader> h_loader(
              hs.NewHandle(soa.Decode<mirror::ClassLoader>(class_loader)));
          // Can not load app image without class loader.
          if (h_loader != nullptr) {
            std::string temp_error_msg;
            // Add image space has a race condition since other threads could be reading from the
            // spaces array.
            {
              ScopedThreadSuspension sts(self, kSuspended);
              gc::ScopedGCCriticalSection gcs(self,
                                              gc::kGcCauseAddRemoveAppImageSpace,
                                              gc::kCollectorTypeAddRemoveAppImageSpace);
              ScopedSuspendAll ssa("Add image space");
              runtime->GetHeap()->AddSpace(image_space.get());
            }
            {
              ScopedTrace image_space_timing(
                  StringPrintf("Adding image space for location %s", dex_location));
              added_image_space = runtime->GetClassLinker()->AddImageSpace(image_space.get(),
                                                                           h_loader,
                                                                           /*out*/&dex_files,
                                                                           /*out*/&temp_error_msg);
            }
            if (added_image_space) {
              // Successfully added image space to heap, release the map so that it does not get
              // freed.
              image_space.release();  // NOLINT b/117926937

              // Register for tracking.
              for (const auto& dex_file : dex_files) {
                dex::tracking::RegisterDexFile(dex_file.get());
              }
            } else {
              LOG(INFO) << "Failed to add image file " << temp_error_msg;
              dex_files.clear();
              {
                ScopedThreadSuspension sts(self, kSuspended);
                gc::ScopedGCCriticalSection gcs(self,
                                                gc::kGcCauseAddRemoveAppImageSpace,
                                                gc::kCollectorTypeAddRemoveAppImageSpace);
                ScopedSuspendAll ssa("Remove image space");
                runtime->GetHeap()->RemoveSpace(image_space.get());
              }
              // Non-fatal, don't update error_msg.
            }
          }
        }
      }
      if (!added_image_space) {
        DCHECK(dex_files.empty());

        if (oat_file->RequiresImage()) {
          VLOG(oat) << "Loading "
                    << oat_file->GetLocation()
                    << "non-executable as it requires an image which we failed to load";
          // file as non-executable.
          OatFileAssistant nonexecutable_oat_file_assistant(dex_location,
                                                            kRuntimeISA,
                                                            /*load_executable=*/false,
                                                            only_use_system_oat_files_);
          oat_file.reset(nonexecutable_oat_file_assistant.GetBestOatFile().release());
        }

        dex_files = oat_file_assistant.LoadDexFiles(*oat_file.get(), dex_location);

        // Register for tracking.
        for (const auto& dex_file : dex_files) {
          dex::tracking::RegisterDexFile(dex_file.get());
        }
      }
      if (dex_files.empty()) {
        error_msgs->push_back("Failed to open dex files from " + oat_file->GetLocation());
      } else {
        // Opened dex files from an oat file, madvise them to their loaded state.
         for (const std::unique_ptr<const DexFile>& dex_file : dex_files) {
           OatDexFile::MadviseDexFile(*dex_file, MadviseState::kMadviseStateAtLoad);
         }
      }

      VLOG(class_linker) << "Registering " << oat_file->GetLocation();
      source_oat_file = RegisterOatFile(std::move(oat_file));
      *out_oat_file = source_oat_file;
    } else if (!error_msg.empty()) {
      LOG(WARNING) << error_msg;
    }

    // Verify if any of the dex files being loaded is already in the class path.
    // If so, report an error with the current stack trace.
    // Most likely the developer didn't intend to do this because it will waste
    // performance and memory.
    if (context != nullptr && !class_loader_context_matches) {
      std::set<const DexFile*> already_exists_in_classpath =
          context->CheckForDuplicateDexFiles(MakeNonOwningPointerVector(dex_files));
      if (!already_exists_in_classpath.empty()) {
        auto duplicate_it = already_exists_in_classpath.begin();
        std::string duplicates = (*duplicate_it)->GetLocation();
        for (duplicate_it++ ; duplicate_it != already_exists_in_classpath.end(); duplicate_it++) {
          duplicates += "," + (*duplicate_it)->GetLocation();
        }

        std::ostringstream out;
        out << "Trying to load dex files which is already loaded in the same ClassLoader "
            << "hierarchy.\n"
            << "This is a strong indication of bad ClassLoader construct which leads to poor "
            << "performance and wastes memory.\n"
            << "The list of duplicate dex files is: " << duplicates << "\n"
            << "The current class loader context is: "
            << context->EncodeContextForOatFile("") << "\n"
            << "Java stack trace:\n";

        {
          ScopedObjectAccess soa(self);
          self->DumpJavaStack(out);
        }

        // We log this as an ERROR to stress the fact that this is most likely unintended.
        // Note that ART cannot do anything about it. It is up to the app to fix their logic.
        // Here we are trying to give a heads up on why the app might have performance issues.
        LOG(ERROR) << out.str();
      }
    }
  }

  // If we arrive here with an empty dex files list, it means we fail to load
  // it/them through an .oat file.
  if (dex_files.empty()) {
    std::string error_msg;
    static constexpr bool kVerifyChecksum = true;
    const ArtDexFileLoader dex_file_loader;
    if (!dex_file_loader.Open(dex_location,
                              dex_location,
                              Runtime::Current()->IsVerificationEnabled(),
                              kVerifyChecksum,
                              /*out*/ &error_msg,
                              &dex_files)) {
      LOG(WARNING) << error_msg;
      error_msgs->push_back("Failed to open dex files from " + std::string(dex_location)
                            + " because: " + error_msg);
    }
  }

  if (Runtime::Current()->GetJit() != nullptr) {
    Runtime::Current()->GetJit()->RegisterDexFiles(dex_files, class_loader);
  }

  return dex_files;
}
```

art/runtime/class_loader_context.cc

```cpp
std::unique_ptr<ClassLoaderContext> ClassLoaderContext::CreateContextForClassLoader(
    jobject class_loader,
    jobjectArray dex_elements) {
  CHECK(class_loader != nullptr);

  ScopedObjectAccess soa(Thread::Current());
  StackHandleScope<2> hs(soa.Self());
  Handle<mirror::ClassLoader> h_class_loader =
      hs.NewHandle(soa.Decode<mirror::ClassLoader>(class_loader));
  Handle<mirror::ObjectArray<mirror::Object>> h_dex_elements =
      hs.NewHandle(soa.Decode<mirror::ObjectArray<mirror::Object>>(dex_elements));
  std::unique_ptr<ClassLoaderContext> result(new ClassLoaderContext(/*owns_the_dex_files=*/ false));
  if (!result->CreateInfoFromClassLoader(
          soa, h_class_loader, h_dex_elements, nullptr, /*is_shared_library=*/ false)) {
    return nullptr;
  }
  return result;
}
```
CreateContextForClassLoader 首先创建了一个ClassLoaderContext，然后调用CreateInfoFromClassLoader，CreateInfoFromClassLoader的参数来自与java传递过来的值。

```cpp
bool ClassLoaderContext::CreateInfoFromClassLoader(
      ScopedObjectAccessAlreadyRunnable& soa,
      Handle<mirror::ClassLoader> class_loader,
      Handle<mirror::ObjectArray<mirror::Object>> dex_elements,
      ClassLoaderInfo* child_info,
      bool is_shared_library)
    REQUIRES_SHARED(Locks::mutator_lock_) {
  // ...

  ClassLoaderContext::ClassLoaderType type;
  if (IsPathOrDexClassLoader(soa, class_loader)) {
    type = kPathClassLoader;
  } else if (IsDelegateLastClassLoader(soa, class_loader)) {
    type = kDelegateLastClassLoader;
  } else if (IsInMemoryDexClassLoader(soa, class_loader)) {
    type = kInMemoryDexClassLoader;
  } else {
    LOG(WARNING) << "Unsupported class loader";
    return false;
  }

  // Inspect the class loader for its dex files.
  std::vector<const DexFile*> dex_files_loaded;
  CollectDexFilesFromSupportedClassLoader(soa, class_loader, &dex_files_loaded);

  // If we have a dex_elements array extract its dex elements now.
  // This is used in two situations:
  //   1) when a new ClassLoader is created DexPathList will open each dex file sequentially
  //      passing the list of already open dex files each time. This ensures that we see the
  //      correct context even if the ClassLoader under construction is not fully build.
  //   2) when apk splits are loaded on the fly, the framework will load their dex files by
  //      appending them to the current class loader. When the new code paths are loaded in
  //      BaseDexClassLoader, the paths already present in the class loader will be passed
  //      in the dex_elements array.
  if (dex_elements != nullptr) {
    GetDexFilesFromDexElementsArray(soa, dex_elements, &dex_files_loaded);
  }

  ClassLoaderInfo* info = new ClassLoaderContext::ClassLoaderInfo(type);
  // Attach the `ClassLoaderInfo` now, before populating dex files, as only the
  // `ClassLoaderContext` knows whether these dex files should be deleted or not.
  if (child_info == nullptr) {
    class_loader_chain_.reset(info);
  } else if (is_shared_library) {
    child_info->shared_libraries.push_back(std::unique_ptr<ClassLoaderInfo>(info));
  } else {
    child_info->parent.reset(info);
  }

  // Now that `info` is in the chain, populate dex files.
  for (const DexFile* dex_file : dex_files_loaded) {
    // Dex location of dex files loaded with InMemoryDexClassLoader is always bogus.
    // Use a magic value for the classpath instead.
    info->classpath.push_back((type == kInMemoryDexClassLoader)
        ? kInMemoryDexClassLoaderDexLocationMagic
        : dex_file->GetLocation());
    info->checksums.push_back(dex_file->GetLocationChecksum());
    info->opened_dex_files.emplace_back(dex_file);
  }

  // Note that dex_elements array is null here. The elements are considered to be part of the
  // current class loader and are not passed to the parents.
  ScopedNullHandle<mirror::ObjectArray<mirror::Object>> null_dex_elements;

  // Add the shared libraries.
  StackHandleScope<3> hs(Thread::Current());
  ArtField* field =
      jni::DecodeArtField(WellKnownClasses::dalvik_system_BaseDexClassLoader_sharedLibraryLoaders);
  ObjPtr<mirror::Object> raw_shared_libraries = field->GetObject(class_loader.Get());
  if (raw_shared_libraries != nullptr) {
    Handle<mirror::ObjectArray<mirror::ClassLoader>> shared_libraries =
        hs.NewHandle(raw_shared_libraries->AsObjectArray<mirror::ClassLoader>());
    MutableHandle<mirror::ClassLoader> temp_loader = hs.NewHandle<mirror::ClassLoader>(nullptr);
    for (auto library : shared_libraries.Iterate<mirror::ClassLoader>()) {
      temp_loader.Assign(library);
      if (!CreateInfoFromClassLoader(
              soa, temp_loader, null_dex_elements, info, /*is_shared_library=*/ true)) {
        return false;
      }
    }
  }

  // We created the ClassLoaderInfo for the current loader. Move on to its parent.
  Handle<mirror::ClassLoader> parent = hs.NewHandle(class_loader->GetParent());
  if (!CreateInfoFromClassLoader(
          soa, parent, null_dex_elements, info, /*is_shared_library=*/ false)) {
    return false;
  }
  return true;
}
```

CreateInfoFromClassLoader函数首先

1. 会去判断当前的class loader类型，也就是前面我们说的那几个 path/dex class loader, in memory dex class loader.

2. CollectDexFilesFromSupportedClassLoader 收集已经加载过的dex file

3. 收集当前 GetDexFilesFromDexElementsArray class loader里的dex file

4. 将已经加载的dex file添加到class loader info里

5. 递归调用至父加载器

在收集到当前class loader 的 info之后 CreateContextForClassLoader 就执行结束了。函数再到OpenDexFilesFromOat中继续执行，这时候我们已经获得了class loader的info。然后创建OatFileAssistant, OatFileAssistant能够获取到oat文件，oat就是dex被编译后的文件。

当获取到oat文件后，并且class loader的上下文也拿到了，那么就去验证class loader 的上下文。验证完之后回去检查当前的oat文件是否可以执行，如果可以执行，那么就从oat文件中加载dex， 否则从image中去加载dex文件。最后如果加载dex成功了，那么就当前的dex信息注册到jit编译器中。


我们可以看下OatFileAssistant的具体实现。

art/runtime/oat_file_assistant.cc

```cpp
OatFileAssistant::OatFileAssistant(const char* dex_location,
                                   const InstructionSet isa,
                                   bool load_executable,
                                   bool only_load_system_executable,
                                   int vdex_fd,
                                   int oat_fd,
                                   int zip_fd)
    : isa_(isa),
      load_executable_(load_executable),
      only_load_system_executable_(only_load_system_executable),
      odex_(this, /*is_oat_location=*/ false),
      oat_(this, /*is_oat_location=*/ true),
      zip_fd_(zip_fd) {
  CHECK(dex_location != nullptr) << "OatFileAssistant: null dex location";

  // ...

  dex_location_.assign(dex_location);

  // ...

  // Get the odex filename.
  std::string error_msg;
  std::string odex_file_name;
  if (DexLocationToOdexFilename(dex_location_, isa_, &odex_file_name, &error_msg)) {
    odex_.Reset(odex_file_name, UseFdToReadFiles(), zip_fd, vdex_fd, oat_fd);
  } else {
    LOG(WARNING) << "Failed to determine odex file name: " << error_msg;
  }

  if (!UseFdToReadFiles()) {
    // Get the oat filename.
    std::string oat_file_name;
    if (DexLocationToOatFilename(dex_location_, isa_, &oat_file_name, &error_msg)) {
      oat_.Reset(oat_file_name, /*use_fd=*/ false);
    } else {
      LOG(WARNING) << "Failed to determine oat file name for dex location "
                   << dex_location_ << ": " << error_msg;
    }
  }

  // ...
}
```

ctor会记录下dex文件的路径，并且会推断出当前dex file的oat文件, odex文件。

获取oat的函数

```cpp
std::unique_ptr<OatFile> OatFileAssistant::GetBestOatFile() {
  return GetBestInfo().ReleaseFileForUse();
}
```

```cpp
OatFileAssistant::OatFileInfo& OatFileAssistant::GetBestInfo() {
  ScopedTrace trace("GetBestInfo");
  // TODO(calin): Document the side effects of class loading when
  // running dalvikvm command line.
  if (dex_parent_writable_ || UseFdToReadFiles()) {
    // If the parent of the dex file is writable it means that we can
    // create the odex file. In this case we unconditionally pick the odex
    // as the best oat file. This corresponds to the regular use case when
    // apps gets installed or when they load private, secondary dex file.
    // For apps on the system partition the odex location will not be
    // writable and thus the oat location might be more up to date.
    return odex_;
  }

  // We cannot write to the odex location. This must be a system app.

  // If the oat location is usable take it.
  if (oat_.IsUseable()) {
    return oat_;
  }

  // The oat file is not usable but the odex file might be up to date.
  // This is an indication that we are dealing with an up to date prebuilt
  // (that doesn't need relocation).
  if (odex_.Status() == kOatUpToDate) {
    return odex_;
  }

  // We got into the worst situation here:
  // - the oat location is not usable
  // - the prebuild odex location is not up to date
  // - and we don't have the original dex file anymore (stripped).
  // Pick the odex if it exists, or the oat if not.
  return (odex_.Status() == kOatCannotOpen) ? oat_ : odex_;
}
```

这里优先返回的是odex文件，将odex文件看作是最优的OatFile

回到OpenDexFilesFromOat文件，如果返回的oat file能够执行，也就是oat文件， 那么就调用 OpenImageSpace 打开oat文件 否则 调用 LoadDexFiles 打开文件

如果上面两个方法都没有成功打开dex file，还有一个fallback方案 ArtDexFileLoader 的 Open 方法

打开oat文件 先找到对应文件的art文件，然后调用 gc::space::ImageSpace::CreateFromAppImage 创建 ImageSpace

art/runtime/oat_file_assistant.cc
```cpp
std::unique_ptr<gc::space::ImageSpace> OatFileAssistant::OpenImageSpace(const OatFile* oat_file) {
  DCHECK(oat_file != nullptr);
  std::string art_file = ReplaceFileExtension(oat_file->GetLocation(), "art");
  if (art_file.empty()) {
    return nullptr;
  }
  std::string error_msg;
  ScopedObjectAccess soa(Thread::Current());
  std::unique_ptr<gc::space::ImageSpace> ret =
      gc::space::ImageSpace::CreateFromAppImage(art_file.c_str(), oat_file, &error_msg);
  if (ret == nullptr && (VLOG_IS_ON(image) || OS::FileExists(art_file.c_str()))) {
    LOG(INFO) << "Failed to open app image " << art_file.c_str() << " " << error_msg;
  }
  return ret;
}
```

art/runtime/gc/space/image_space.cc
```cpp
std::unique_ptr<ImageSpace> ImageSpace::CreateFromAppImage(const char* image,
                                                           const OatFile* oat_file,
                                                           std::string* error_msg) {
  // Note: The oat file has already been validated.
  const std::vector<ImageSpace*>& boot_image_spaces =
      Runtime::Current()->GetHeap()->GetBootImageSpaces();
  return CreateFromAppImage(image,
                            oat_file,
                            ArrayRef<ImageSpace* const>(boot_image_spaces),
                            error_msg);
}
```

函数只是把请求转发到了CreateFromAppImage中

```cpp
std::unique_ptr<ImageSpace> ImageSpace::CreateFromAppImage(
    const char* image,
    const OatFile* oat_file,
    ArrayRef<ImageSpace* const> boot_image_spaces,
    std::string* error_msg) {
  return Loader::InitAppImage(image,
                              image,
                              oat_file,
                              boot_image_spaces,
                              error_msg);
}
```

然后继续转发到InitAppImage中, 源码暂时没有跟到，看起来到了bootloader中


```cpp
bool OatFileAssistant::LoadDexFiles(
    const OatFile &oat_file,
    const std::string& dex_location,
    std::vector<std::unique_ptr<const DexFile>>* out_dex_files) {
  // Load the main dex file.
  std::string error_msg;
  const OatDexFile* oat_dex_file = oat_file.GetOatDexFile(
      dex_location.c_str(), nullptr, &error_msg);
  if (oat_dex_file == nullptr) {
    LOG(WARNING) << error_msg;
    return false;
  }

  std::unique_ptr<const DexFile> dex_file = oat_dex_file->OpenDexFile(&error_msg);
  if (dex_file.get() == nullptr) {
    LOG(WARNING) << "Failed to open dex file from oat dex file: " << error_msg;
    return false;
  }
  out_dex_files->push_back(std::move(dex_file));

  // Load the rest of the multidex entries
  for (size_t i = 1;; i++) {
    std::string multidex_dex_location = DexFileLoader::GetMultiDexLocation(i, dex_location.c_str());
    oat_dex_file = oat_file.GetOatDexFile(multidex_dex_location.c_str(), nullptr);
    if (oat_dex_file == nullptr) {
      // There are no more multidex entries to load.
      break;
    }

    dex_file = oat_dex_file->OpenDexFile(&error_msg);
    if (dex_file.get() == nullptr) {
      LOG(WARNING) << "Failed to open dex file from oat dex file: " << error_msg;
      return false;
    }
    out_dex_files->push_back(std::move(dex_file));
  }
  return true;
}
```

这个函数首先去拿到oat文件路径，然后打开dexfile，后面一个是处理multidex的case，先看oat文件路径怎么拿到的

art/runtime/oat_file.cc
```cpp
const OatDexFile* OatFile::GetOatDexFile(const char* dex_location,
                                         const uint32_t* dex_location_checksum,
                                         std::string* error_msg) const {
  // NOTE: We assume here that the canonical location for a given dex_location never
  // changes. If it does (i.e. some symlink used by the filename changes) we may return
  // an incorrect OatDexFile. As long as we have a checksum to check, we shall return
  // an identical file or fail; otherwise we may see some unpredictable failures.

  // TODO: Additional analysis of usage patterns to see if this can be simplified
  // without any performance loss, for example by not doing the first lock-free lookup.

  const OatDexFile* oat_dex_file = nullptr;
  std::string_view key(dex_location);
  // Try to find the key cheaply in the oat_dex_files_ map which holds dex locations
  // directly mentioned in the oat file and doesn't require locking.
  auto primary_it = oat_dex_files_.find(key);
  if (primary_it != oat_dex_files_.end()) {
    oat_dex_file = primary_it->second;
    DCHECK(oat_dex_file != nullptr);
  } else {
    // This dex_location is not one of the dex locations directly mentioned in the
    // oat file. The correct lookup is via the canonical location but first see in
    // the secondary_oat_dex_files_ whether we've looked up this location before.
    MutexLock mu(Thread::Current(), secondary_lookup_lock_);
    auto secondary_lb = secondary_oat_dex_files_.lower_bound(key);
    if (secondary_lb != secondary_oat_dex_files_.end() && key == secondary_lb->first) {
      oat_dex_file = secondary_lb->second;  // May be null.
    } else {
      // We haven't seen this dex_location before, we must check the canonical location.
      std::string dex_canonical_location = DexFileLoader::GetDexCanonicalLocation(dex_location);
      if (dex_canonical_location != dex_location) {
        std::string_view canonical_key(dex_canonical_location);
        auto canonical_it = oat_dex_files_.find(canonical_key);
        if (canonical_it != oat_dex_files_.end()) {
          oat_dex_file = canonical_it->second;
        }  // else keep null.
      }  // else keep null.

      // Copy the key to the string_cache_ and store the result in secondary map.
      string_cache_.emplace_back(key.data(), key.length());
      std::string_view key_copy(string_cache_.back());
      secondary_oat_dex_files_.PutBefore(secondary_lb, key_copy, oat_dex_file);
    }
  }

  if (oat_dex_file == nullptr) {
    if (error_msg != nullptr) {
      std::string dex_canonical_location = DexFileLoader::GetDexCanonicalLocation(dex_location);
      *error_msg = "Failed to find OatDexFile for DexFile " + std::string(dex_location)
          + " (canonical path " + dex_canonical_location + ") in OatFile " + GetLocation();
    }
    return nullptr;
  }

  if (dex_location_checksum != nullptr &&
      oat_dex_file->GetDexFileLocationChecksum() != *dex_location_checksum) {
    if (error_msg != nullptr) {
      std::string dex_canonical_location = DexFileLoader::GetDexCanonicalLocation(dex_location);
      std::string checksum = StringPrintf("0x%08x", oat_dex_file->GetDexFileLocationChecksum());
      std::string required_checksum = StringPrintf("0x%08x", *dex_location_checksum);
      *error_msg = "OatDexFile for DexFile " + std::string(dex_location)
          + " (canonical path " + dex_canonical_location + ") in OatFile " + GetLocation()
          + " has checksum " + checksum + " but " + required_checksum + " was required";
    }
    return nullptr;
  }
  return oat_dex_file;
}
```

这个方法回去找oat文件位置，首先会从两个内存缓存中去查找，如果都没找到，那么就要从磁盘上进行读取

DexFileLoader::GetDexCanonicalLocation(dex_location); 会返回最终的dex文件位置, 缓存是在创建OatFile的时候同时创建的。


总结一下，创建一个class loader的过程。

1. 根据文件路径传递到c层
2. c层将dex文件路径转化成OatFile， 核心是OatFileAssistant这个文件