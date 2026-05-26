import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; 
import 'package:path/path.dart' as p; 
import 'package:file_picker/file_picker.dart'; 
import 'package:open_filex/open_filex.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_win/video_player_win_plugin.dart';

void main() {
  if (Platform.isWindows) {
    WindowsVideoPlayer.registerWith();
  }
  runApp(const ImageOrganizerApp());
}

class ImageOrganizerApp extends StatelessWidget {
  const ImageOrganizerApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Media Organizer Pro',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true),
        home: const ImageRenameScreen(),
      );
}

class ImageRenameScreen extends StatefulWidget {
  const ImageRenameScreen({super.key});
  @override
  State<ImageRenameScreen> createState() => _ImageRenameScreenState();
}

class _ImageRenameScreenState extends State<ImageRenameScreen> {
  List<File> _allFiles = [];
  int _currentIndex = 0;
  int _pageSize = 12; 
  String _sourcePath = "";
  String _targetPath = ""; 
  String _editorPath = ""; 
  final Set<String> _selectedPaths = {}; 
  final Set<String> _markedForSave = {}; 
  final Map<String, TextEditingController> _controllers = {};
  
  // Expanded to support common video extensions alongside images
  final List<String> _imageExtensions = ['.jpg', '.jpeg', '.png', '.webp', '.bmp'];
  final List<String> _videoExtensions = ['.mp4', '.mov', '.avi', '.mkv'];
  
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadStoredPreferences();
  }

  Future<void> _loadStoredPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final List<int> allowedSizes = [12, 24, 48, 100];
    setState(() {
      _sourcePath = prefs.getString('sourcePath') ?? "";
      _targetPath = prefs.getString('targetPath') ?? "";
      _editorPath = prefs.getString('editorPath') ?? "";
      int savedSize = prefs.getInt('pageSize') ?? 12;
      _pageSize = allowedSizes.contains(savedSize) ? savedSize : 12;
    });
    if (_sourcePath.isNotEmpty) _loadFiles();
  }

  Future<void> _savePreference(String key, dynamic value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value is String) await prefs.setString(key, value);
    if (value is int) await prefs.setInt(key, value);
  }

  Future<void> _selectSourceDirectory() async {
    String? path = await FilePicker.platform.getDirectoryPath();
    if (path != null) {
      setState(() {
        _sourcePath = path;
        _currentIndex = 0;
        _selectedPaths.clear();
        _markedForSave.clear();
      });
      _savePreference('sourcePath', path);
      _loadFiles();
    }
  }

  Future<void> _selectTargetDirectory() async {
    String? path = await FilePicker.platform.getDirectoryPath();
    if (path != null) {
      setState(() => _targetPath = path);
      _savePreference('targetPath', path);
    }
  }

  Future<void> _selectEditorApp() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom, 
      allowedExtensions: ['exe']
    );
    if (result != null && result.files.single.path != null) {
      setState(() => _editorPath = result.files.single.path!);
      _savePreference('editorPath', _editorPath);
    }
  }

  void _loadFiles() {
    if (_sourcePath.isEmpty) return;
    final dir = Directory(_sourcePath);
    if (dir.existsSync()) {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      double currentOffset = _scrollController.hasClients ? _scrollController.offset : 0.0;

      setState(() {
        _controllers.forEach((k, v) => v.dispose());
        _controllers.clear();
        
        // Combines both valid image and video lists for standard discovery
        final validExtensions = [..._imageExtensions, ..._videoExtensions];
        
        _allFiles = dir
            .listSync()
            .whereType<File>()
            .where((f) => validExtensions.contains(p.extension(f.path).toLowerCase()))
            .toList();
        _allFiles.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) _scrollController.jumpTo(currentOffset);
      });
    }
  }

  void _openMedia(String filePath) {
    if (_editorPath.isNotEmpty && File(_editorPath).existsSync()) {
      Process.run(_editorPath, [filePath]);
    } else {
      OpenFilex.open(filePath);
    }
  }

  Future<void> _processMarkedFiles() async {
    if (_targetPath.isEmpty) return;
    for (String path in _markedForSave) {
      File(path).copySync(p.join(_targetPath, p.basename(path)));
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Copied ${_markedForSave.length} items.")));
    setState(() => _markedForSave.clear());
  }

  void _renameFile(File file, String newName) {
    if (newName.isEmpty) return;
    String newPath = p.join(p.dirname(file.path), "$newName${p.extension(file.path)}");
    try {
      File newFile = file.renameSync(newPath);
      setState(() {
        int index = _allFiles.indexOf(file);
        if (index != -1) _allFiles[index] = newFile;
        final oldController = _controllers.remove(file.path);
        _controllers[newPath] = oldController ?? TextEditingController();
        _controllers[newPath]?.clear();
      });
    } catch (e) {
      debugPrint("Rename failed: $e");
    }
  }

  void _startSlideshow() {
    if (_allFiles.isEmpty) return;

    // Filters out videos for the slideshow since it uses regular image rendering primitives
    List<File> playlist = (_selectedPaths.isNotEmpty
        ? _allFiles.where((f) => _selectedPaths.contains(f.path)).toList()
        : _allFiles).where((f) => _imageExtensions.contains(p.extension(f.path).toLowerCase())).toList();

    if (playlist.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("No images selected for slideshow.")));
      return;
    }

    int seconds = 3; 
    bool shuffle = false;

    showDialog(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text("Slideshow Settings"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Text("Seconds per image: "),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 60,
                    child: TextFormField(
                      initialValue: "3",
                      keyboardType: TextInputType.number,
                      onChanged: (v) => seconds = int.tryParse(v) ?? 3,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 15),
              Row(
                children: [
                  const Text("Display randomly (Shuffle): "),
                  Checkbox(
                    value: shuffle,
                    activeColor: Colors.greenAccent.shade700,
                    onChanged: (val) {
                      setDialogState(() => shuffle = val ?? false);
                    },
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text("Cancel")),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(c);
                
                List<File> finalPlaylist = List<File>.from(playlist);
                if (shuffle) {
                  finalPlaylist.shuffle();
                }

                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => FullscreenSlideshowWidget(
                      images: finalPlaylist, 
                      intervalSeconds: seconds
                    ),
                  ),
                );
              },
              child: const Text("Start"),
            ),
          ],
        ),
      ),
    );
  }

  void _showBatchRenameDialog() {
    String prefix = "";
    showDialog(context: context, builder: (c) => AlertDialog(
      title: const Text("Batch Rename"), 
      content: TextField(autofocus: true, onChanged: (v) => prefix = v, decoration: const InputDecoration(hintText: "Prefix_")), 
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text("Cancel")), 
        ElevatedButton(onPressed: () {
          if (prefix.isEmpty) return;
          int nextNum = 1;
          final regex = RegExp('^${RegExp.escape(prefix)}(\\d+)\\.');
          for (var f in _allFiles) {
            final match = regex.firstMatch(p.basename(f.path));
            if (match != null) {
              int n = int.tryParse(match.group(1) ?? "0") ?? 0;
              if (n >= nextNum) nextNum = n + 1;
            }
          }
          List<File> targets = _selectedPaths.isNotEmpty 
              ? _allFiles.where((f) => _selectedPaths.contains(f.path)).toList() 
              : _allFiles.skip(_currentIndex).take(_pageSize).toList();
          for (int i = 0; i < targets.length; i++) {
            targets[i].renameSync(p.join(p.dirname(targets[i].path), "$prefix${nextNum + i}${p.extension(targets[i].path)}"));
          }
          _selectedPaths.clear(); _loadFiles(); Navigator.pop(c);
        }, child: const Text("Rename"))
      ]));
  }

  void _deleteBulk() {
    if (_selectedPaths.isEmpty) return;
    final List<String> pathsToDelete = List<String>.from(_selectedPaths);

    try {
      for (var path in pathsToDelete) {
        final f = File(path);
        if (f.existsSync()) {
          try {
            _moveToRecycleBin(path);
          } catch (e) {
            debugPrint("Failed to delete $path: $e");
          }
        }
      }
    } finally {
      setState(() {
        _selectedPaths.clear();
        _markedForSave.clear();
      });
      _loadFiles();
    }
  }

  void _moveToRecycleBin(String path) {
    if (Platform.isWindows) {
      Process.runSync(
        'powershell',
        [
          '-command',
          r'Add-Type -AssemblyName Microsoft.VisualBasic; [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($env:FILE_PATH, "OnlyErrorDialogs", "SendToRecycleBin")'
        ],
        // Passing the path as an environment variable prevents issues with spaces or quotes in file names
        environment: {'FILE_PATH': path},
      );
    } else if (Platform.isMacOS) {
      // Uses macOS AppleScript to ask Finder to send the file to the Trash
      Process.runSync('osascript', ['-e', 'tell application "Finder" to delete POSIX file "$path"']);
    } else if (Platform.isLinux) {
      // Uses the standard GNOME/Linux gio command to move the file to the Trash
      Process.runSync('gio', ['trash', path]);
    } else {
      File(path).deleteSync();
    }
  }

  void _showZoomDialog(File initialFile) {
    // Get all valid images in the current folder
    List<File> imageFiles = _allFiles.where((f) => _imageExtensions.contains(p.extension(f.path).toLowerCase())).toList();
    int currentIndex = imageFiles.indexOf(initialFile);
    if (currentIndex == -1) currentIndex = 0; 

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return Dialog(
            backgroundColor: Colors.black,
            insetPadding: const EdgeInsets.all(24),
            child: Stack(
              children: [
                SizedBox.expand(
                  child: InteractiveViewer(
                    key: ValueKey(imageFiles[currentIndex].path),
                    maxScale: 5.0,
                    child: Image.file(imageFiles[currentIndex], fit: BoxFit.contain),
                  ),
                ),
                Positioned(
                  top: 8, right: 8,
                  child: Container(
                    decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                    child: IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ),
                ),
                if (currentIndex > 0)
                  Positioned(
                    left: 8, top: 0, bottom: 0,
                    child: Center(
                      child: Container(
                        decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                        child: IconButton(
                          iconSize: 32,
                          icon: const Icon(Icons.chevron_left, color: Colors.white),
                          onPressed: () => setDialogState(() => currentIndex--),
                        ),
                      ),
                    ),
                  ),
                if (currentIndex < imageFiles.length - 1)
                  Positioned(
                    right: 8, top: 0, bottom: 0,
                    child: Center(
                      child: Container(
                        decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                        child: IconButton(
                          iconSize: 32,
                          icon: const Icon(Icons.chevron_right, color: Colors.white),
                          onPressed: () => setDialogState(() => currentIndex++),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        }
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    var displayed = _allFiles.skip(_currentIndex).take(_pageSize).toList();
    double cardWidth = (MediaQuery.of(context).size.width - 48) / 4;

    return Scaffold(
      appBar: AppBar(
        title: Text(_sourcePath.isEmpty ? "Media Organizer" : "Source: ${p.basename(_sourcePath)}"),
        bottom: PreferredSize(preferredSize: const Size.fromHeight(50), child: _buildSubHeader()),
        actions: [
          if (_allFiles.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.play_circle_outline, color: Colors.greenAccent), 
              onPressed: _startSlideshow,
              tooltip: "Play Image Slideshow",
            ),
          IconButton(icon: const Icon(Icons.folder_open), onPressed: _selectSourceDirectory, tooltip: "Select Source Folder"),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadFiles, tooltip: "Refresh Grid"),
        ],
      ),
      body: _sourcePath.isEmpty
          ? Center(child: ElevatedButton.icon(onPressed: _selectSourceDirectory, icon: const Icon(Icons.folder_open), label: const Text("Select Source Folder")))
          : SingleChildScrollView( 
              controller: _scrollController,
              padding: const EdgeInsets.all(8),
              child: Wrap(
                spacing: 8, runSpacing: 8,
                children: displayed.map((file) => _buildMediaCard(file, cardWidth)).toList(),
              ),
            ),
      bottomNavigationBar: _buildBottomBar(),
    );
  }

  Widget _buildSubHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Text(_targetPath.isEmpty ? "Target not set" : "Target: ${p.basename(_targetPath)}", style: const TextStyle(color: Colors.cyan, fontSize: 11)),
          const SizedBox(width: 8),
          TextButton.icon(onPressed: _selectTargetDirectory, icon: const Icon(Icons.folder_shared, size: 14), label: const Text("Set Target", style: TextStyle(fontSize: 11))),
          const VerticalDivider(width: 20),
          Text(_editorPath.isEmpty ? "Default Player" : "Player: ${p.basename(_editorPath)}", style: const TextStyle(color: Colors.amber, fontSize: 11)),
          const SizedBox(width: 8),
          TextButton.icon(onPressed: _selectEditorApp, icon: const Icon(Icons.edit_note, size: 14), label: const Text("Set Player App", style: TextStyle(fontSize: 11))),
          const Spacer(),
          if (_markedForSave.isNotEmpty)
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.cyan.shade900),
              onPressed: _processMarkedFiles,
              icon: const Icon(Icons.send_and_archive, size: 16),
              label: Text("Save Marked (${_markedForSave.length})"),
            ),
        ],
      ),
    );
  }

  Widget _buildMediaCard(File file, double width) {
    bool isSelected = _selectedPaths.contains(file.path);
    bool isMarked = _markedForSave.contains(file.path);
    bool isVideo = _videoExtensions.contains(p.extension(file.path).toLowerCase());
    _controllers.putIfAbsent(file.path, () => TextEditingController());

    return SizedBox(
      width: width,
      child: Card(
        margin: EdgeInsets.zero,
        color: isSelected ? Colors.blueGrey.shade800 : null,
        shape: isSelected ? RoundedRectangleBorder(side: const BorderSide(color: Colors.blue, width: 2), borderRadius: BorderRadius.circular(8)) : null,
        child: Column(
          mainAxisSize: MainAxisSize.min, 
          children: [
            Stack(
              children: [
                Container(
                  height: width * 0.65, // Enforces standard layout constraints
                  color: Colors.black12,
                  child: Center(
                    child: InkWell(
                      onTap: () => setState(() => isSelected ? _selectedPaths.remove(file.path) : _selectedPaths.add(file.path)),
                      onDoubleTap: isVideo ? () {
                        showDialog(context: context, builder: (_) => VideoPlayerDialog(videoFile: file));
                      } : () => _showZoomDialog(file),
                      // Route rendering dynamically depending on file type signature
                      child: isVideo 
                          ? EmbeddedVideoThumbnail(videoFile: file)
                          : Image.file(file, fit: BoxFit.contain, cacheWidth: 400, key: ValueKey("${file.path}_${file.lastModifiedSync()}")), 
                    ),
                  ),
                ),
                Positioned(
                  top: 0, left: 0,
                  child: Checkbox(
                    value: isMarked, activeColor: Colors.cyan,
                    onChanged: (val) => setState(() => val! ? _markedForSave.add(file.path) : _markedForSave.remove(file.path)),
                  ),
                ),
                if (isSelected) const Positioned(top: 8, right: 8, child: Icon(Icons.check_circle, color: Colors.blue, size: 20)),
                if (isVideo) const Positioned(bottom: 8, right: 8, child: Icon(Icons.videocam, color: Colors.amberAccent, size: 20)),
              ],
            ),
            Padding(padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4), child: Text(p.basename(file.path), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500), overflow: TextOverflow.ellipsis)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: TextField(
                controller: _controllers[file.path], 
                style: const TextStyle(fontSize: 14),
                decoration: const InputDecoration(isDense: true, hintText: "Rename...", contentPadding: EdgeInsets.symmetric(vertical: 6)),
                onSubmitted: (v) => _renameFile(file, v),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly, 
              children: [
                IconButton(icon: const Icon(Icons.check, size: 14, color: Colors.green), onPressed: () => _renameFile(file, _controllers[file.path]!.text)),
                IconButton(icon: const Icon(Icons.info_outline, size: 14, color: Colors.amber), onPressed: () {
                  final stats = file.statSync();
                  showDialog(context: context, builder: (c) => AlertDialog(title: const Text("Info"), content: Text("Size: ${(stats.size / (1024 * 1024)).toStringAsFixed(2)} MB\nModified: ${stats.modified}"), actions: [TextButton(onPressed: ()=>Navigator.pop(c), child: const Text("Close"))]));
                }),
              if (isVideo)
                IconButton(icon: const Icon(Icons.play_arrow, size: 14, color: Colors.blue), onPressed: () => _openMedia(file.path))
              else 
                IconButton(icon: const Icon(Icons.open_in_new, size: 14, color: Colors.blue), onPressed: () => _openMedia(file.path)),
              IconButton(icon: const Icon(Icons.delete_outline, size: 14, color: Colors.redAccent), onPressed: () { _moveToRecycleBin(file.path); _loadFiles(); }),
              ],
            )
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    if (_sourcePath.isEmpty) return const SizedBox.shrink();

    int currentPage = (_currentIndex / _pageSize).floor() + 1;
    int totalPages = (_allFiles.length / _pageSize).ceil();
    if (totalPages < 1) totalPages = 1; 

    return Container(
      padding: const EdgeInsets.all(8), color: Colors.black26,
      child: Row(
        children: [
          Text("${_selectedPaths.length} sel / ${_allFiles.length} tot", style: const TextStyle(fontSize: 11)),
          const SizedBox(
            height: 16,
            child: VerticalDivider(width: 16, indent: 4, endIndent: 4),
          ),
          Text("Page $currentPage of $totalPages", style: const TextStyle(fontSize: 11, color: Colors.grey)),
          const SizedBox(width: 12),
          const Text("View:", style: TextStyle(fontSize: 11)),
          const SizedBox(width: 4),
          DropdownButton<int>(
            value: _pageSize,
            items: [12, 24, 48, 100].map((v) => DropdownMenuItem(value: v, child: Text(v.toString(), style: const TextStyle(fontSize: 11)))).toList(),
            onChanged: (val) {
              setState(() { _pageSize = val!; _currentIndex = 0; });
              final dynamic outVal = val;
              SharedPreferences.getInstance().then((p) => p.setInt('pageSize', outVal));
              _loadFiles();
            },
          ),
          const Spacer(),
          ElevatedButton(onPressed: _currentIndex > 0 ? () => setState(() { _currentIndex -= _pageSize; _scrollController.jumpTo(0); }) : null, child: const Text("<")),
          const SizedBox(width: 4),
          ElevatedButton(onPressed: _currentIndex + _pageSize < _allFiles.length ? () => setState(() { _currentIndex += _pageSize; _scrollController.jumpTo(0); }) : null, child: const Text(">")),
          const SizedBox(width: 8),
          if (_selectedPaths.isNotEmpty)
            OutlinedButton(onPressed: _deleteBulk, child: const Text("Del Sel", style: TextStyle(color: Colors.redAccent, fontSize: 11))),
          const SizedBox(width: 8),
          OutlinedButton(onPressed: _allFiles.isNotEmpty ? _showBatchRenameDialog : null, child: const Text("Batch Rename", style: TextStyle(fontSize: 11))),
        ],
      ),
    );
  }
}

// BULLETPROOF WIDGET: Simple video thumbnail placeholder
class EmbeddedVideoThumbnail extends StatelessWidget {
  final File videoFile;
  const EmbeddedVideoThumbnail({super.key, required this.videoFile});

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: Container(
        color: Colors.black45,
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.play_circle_outline, size: 40, color: Colors.amberAccent),
            SizedBox(height: 4),
            Text("Video", style: TextStyle(fontSize: 10, color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}

class VideoPlayerDialog extends StatefulWidget {
  final File videoFile;
  const VideoPlayerDialog({super.key, required this.videoFile});

  @override
  State<VideoPlayerDialog> createState() => _VideoPlayerDialogState();
}

class _VideoPlayerDialogState extends State<VideoPlayerDialog> {
  late VideoPlayerController _controller;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(widget.videoFile)
      ..initialize().then((_) {
        setState(() {}); // trigger rebuild to show the video
        _controller.play(); // auto-play on open
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.black,
      insetPadding: const EdgeInsets.all(24),
      child: Stack(
        children: [
          Center(
            child: _controller.value.isInitialized
                ? AspectRatio(
                    aspectRatio: _controller.value.aspectRatio,
                    child: VideoPlayer(_controller),
                  )
                : const CircularProgressIndicator(),
          ),
          Positioned(
            top: 8, right: 8,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 32),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          if (_controller.value.isInitialized)
            Positioned(
              bottom: 16, left: 24, right: 24,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  VideoProgressIndicator(
                    _controller,
                    allowScrubbing: true,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    colors: const VideoProgressColors(playedColor: Colors.blue),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton(
                    backgroundColor: Colors.black54,
                    onPressed: () => setState(() => _controller.value.isPlaying ? _controller.pause() : _controller.play()),
                    child: Icon(_controller.value.isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.white, size: 32),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class FullscreenSlideshowWidget extends StatefulWidget {
  final List<File> images;
  final int intervalSeconds;

  const FullscreenSlideshowWidget({
    super.key, 
    required this.images, 
    required this.intervalSeconds
  });

  @override
  State<FullscreenSlideshowWidget> createState() => _FullscreenSlideshowWidgetState();
}

class _FullscreenSlideshowWidgetState extends State<FullscreenSlideshowWidget> {
  int _index = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  void _startTimer() {
    _timer = Timer.periodic(Duration(seconds: widget.intervalSeconds), (timer) {
      if (mounted) {
        setState(() {
          _index = (_index + 1) % widget.images.length;
        });
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel(); 
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: FocusNode()..requestFocus(), 
      onKeyEvent: (KeyEvent event) {
        if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
          Navigator.pop(context);
        }
      },
      child: GestureDetector(
        onTapDown: (_) => Navigator.pop(context), 
        child: Scaffold(
          backgroundColor: Colors.black,
          body: SizedBox.expand(
              child: InteractiveViewer(
                maxScale: 5.0,
                child: Image.file(
                  widget.images[_index],
                  fit: BoxFit.contain,
                  key: ValueKey(widget.images[_index].path),
                ),
            ),
          ),
        ),
      ),
    );
  }
}