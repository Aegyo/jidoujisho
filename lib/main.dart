import 'dart:io';

import 'package:async/async.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fuzzy/fuzzy.dart';
import 'package:mecab_dart/mecab_dart.dart';
import 'package:package_info/package_info.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:transparent_image/transparent_image.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';

import 'package:jidoujisho/player.dart';
import 'package:jidoujisho/util.dart';

typedef void SearchCallback(String id, String name);

String appDirPath;
String previewImageDir;
String previewAudioDir;

String appName;
String packageName;
String version;
String buildNumber;

Mecab mecabTagger;

List<DictionaryEntry> customDictionary;
Fuzzy customDictionaryFuzzy;

bool isGooglePlayLimited = false;

SharedPreferences globalPrefs;
ValueNotifier<bool> globalSelectMode;
ValueNotifier<bool> globalResumable;

AsyncMemoizer trendingCache = AsyncMemoizer();
AsyncMemoizer channelCache = AsyncMemoizer();
Map<String, AsyncMemoizer> searchCache = {};
Map<String, AsyncMemoizer> captioningCache = {};
Map<String, AsyncMemoizer> channelVideoCache = {};
Map<String, AsyncMemoizer> playlistVideoCache = {};
Map<String, AsyncMemoizer> metadataCache = {};

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIOverlays([]);

  PackageInfo packageInfo = await PackageInfo.fromPlatform();
  appName = packageInfo.appName;
  packageName = packageInfo.packageName;
  version = packageInfo.version;
  buildNumber = packageInfo.buildNumber;

  mecabTagger = Mecab();
  await mecabTagger.init("assets/ipadic", true);

  globalPrefs = await SharedPreferences.getInstance();

  String lastPlayedPath = globalPrefs.getString("lastPlayedPath") ?? "-1";
  globalResumable = ValueNotifier<bool>(lastPlayedPath != "-1");

  bool selectMode = globalPrefs.getBool("selectMode") ?? false;
  globalSelectMode = ValueNotifier<bool>(selectMode);

  await Permission.storage.request();
  requestPermissions();

  Directory appDirDoc = await getApplicationDocumentsDirectory();
  appDirPath = appDirDoc.path;
  previewImageDir = appDirPath + "/exportImage.jpg";
  previewAudioDir = appDirPath + "/exportAudio.mp3";

  customDictionary = importCustomDictionary();
  customDictionaryFuzzy = Fuzzy(getAllImportedWords());

  runApp(App());
}

fetchTrendingCache() {
  return trendingCache.runOnce(() async {
    return searchYouTubeTrendingVideos();
  });
}

fetchChannelCache() {
  return channelCache.runOnce(() async {
    return getSubscribedChannels();
  });
}

fetchSearchCache(String searchQuery) {
  if (searchCache[searchQuery] == null) {
    searchCache[searchQuery] = AsyncMemoizer();
  }
  return searchCache[searchQuery].runOnce(() async {
    return searchYouTubeVideos(searchQuery);
  });
}

fetchChannelVideoCache(String channelID) {
  if (channelVideoCache[channelID] == null) {
    channelVideoCache[channelID] = AsyncMemoizer();
  }
  return channelVideoCache[channelID].runOnce(() async {
    return getLatestChannelVideos(channelID);
  });
}

fetchPlaylistVideoCache(String playlistID) {
  if (playlistVideoCache[playlistID] == null) {
    playlistVideoCache[playlistID] = AsyncMemoizer();
  }
  return playlistVideoCache[playlistID].runOnce(() async {
    return getLatestPlaylistVideos(playlistID);
  });
}

fetchCaptioningCache(String videoID) {
  if (captioningCache[videoID] == null) {
    captioningCache[videoID] = AsyncMemoizer();
  }
  return captioningCache[videoID].runOnce(() async {
    return checkYouTubeClosedCaptionAvailable(videoID);
  });
}

fetchMetadataCache(String videoID, Video video) {
  if (metadataCache[videoID] == null) {
    metadataCache[videoID] = AsyncMemoizer();
  }
  return metadataCache[videoID].runOnce(() async {
    return getPublishMetadata(video);
  });
}

class App extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        accentColor: Colors.red,
        brightness: Brightness.dark,
        backgroundColor: Colors.black,
        cardColor: Colors.black,
        appBarTheme: AppBarTheme(backgroundColor: Colors.black),
        canvasColor: Colors.grey[900],
      ),
      home: Home(),
    );
  }
}

class Home extends StatefulWidget {
  _HomeState createState() => _HomeState();
}

class _HomeState extends State<Home> {
  TextEditingController _searchQueryController = TextEditingController();
  bool _isSearching = false;
  bool _isChannelView = false;
  bool _isPlaylistView = false;
  String searchQuery = "";
  int _selectedIndex = 0;
  String leadingContext = "";

  void _onItemTapped(int index) {
    setState(() {
      if (index == 2) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => Player(
              initialPosition: -1,
            ),
          ),
        ).then((returnValue) {
          setState(() {
            SystemChrome.setPreferredOrientations([
              DeviceOrientation.portraitUp,
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]);
          });
        });
      } else {
        _selectedIndex = index;
        if (_isSearching || _isChannelView || _isPlaylistView) {
          _isSearching = false;
          _isChannelView = false;
          _isPlaylistView = false;
          searchQuery = "";
        }
      }
    });
  }

  static const TextStyle optionStyle =
      TextStyle(fontSize: 30, fontWeight: FontWeight.bold);

  Widget _getWidgetOptions(int index) {
    if (_isSearching) {
      return _buildBody();
    } else if (_isChannelView) {
      return _buildChannels();
    } else if (_isPlaylistView) {
      return _buildPlaylists();
    }

    switch (index) {
      case 0:
        return _buildBody();
      case 1:
        return _buildChannels();
      default:
        return Text("Nothing");
    }
  }

  @override
  Widget build(BuildContext context) {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    return new WillPopScope(
      onWillPop: _onWillPop,
      child: new Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.black,
          leading: _buildAppBarLeading(),
          title: _buildAppBarTitleOrSearch(),
          actions: _buildActions(),
        ),
        backgroundColor: Colors.black,
        bottomNavigationBar: BottomNavigationBar(
          backgroundColor: Colors.black,
          type: BottomNavigationBarType.fixed,
          selectedFontSize: 10,
          unselectedFontSize: 10,
          selectedIconTheme: IconThemeData(color: Colors.white),
          unselectedIconTheme: IconThemeData(color: Colors.grey),
          unselectedLabelStyle: TextStyle(color: Colors.grey),
          selectedLabelStyle: TextStyle(color: Colors.red),
          currentIndex: _selectedIndex,
          onTap: _onItemTapped,
          items: const <BottomNavigationBarItem>[
            BottomNavigationBarItem(
              icon: Icon(Icons.whatshot),
              label: 'Trending',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.subscriptions_sharp),
              label: 'Channels',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.folder),
              label: 'Library',
            ),
          ],
        ),
        body: Center(
          child: _getWidgetOptions(_selectedIndex),
        ),
        // floatingActionButton: FloatingActionButton(
        //   onPressed: () {
        //     Navigator.push(
        //       context,
        //       MaterialPageRoute(
        //         builder: (context) => Player(
        //           initialPosition: -1,
        //         ),
        //       ),
        //     ).then((returnValue) {
        //       setState(() {
        //         SystemChrome.setPreferredOrientations([
        //           DeviceOrientation.portraitUp,
        //           DeviceOrientation.landscapeLeft,
        //           DeviceOrientation.landscapeRight,
        //         ]);
        //       });
        //     });
        //   },
        //   child: Icon(Icons.video_collection_sharp),
        //   backgroundColor: Colors.red,
        //   foregroundColor: Colors.white,
        // ),
      ),
    );
  }

  Future<bool> _onWillPop() async {
    if (_isSearching || _isChannelView || _isPlaylistView) {
      setState(() {
        _isSearching = false;
        _isChannelView = false;
        _isPlaylistView = false;
        searchQuery = "";
      });
    } else {
      SystemChannels.platform.invokeMethod('SystemNavigator.pop');
    }
    return false;
  }

  Widget _buildAppBarLeading() {
    if (_isSearching || _isChannelView || _isPlaylistView) {
      return BackButton(
        onPressed: () {
          setState(() {
            _isSearching = false;
            _isChannelView = false;
            _isPlaylistView = false;
          });
        },
      );
    } else {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 9, 0, 9),
        child: FadeInImage(
          image: AssetImage('assets/icon/icon.png'),
          placeholder: MemoryImage(kTransparentImage),
        ),
      );
    }
  }

  Widget _buildAppBarTitleOrSearch() {
    if (_isSearching) {
      return TextField(
        cursorColor: Colors.red,
        controller: _searchQueryController,
        autofocus: true,
        decoration: InputDecoration(
          hintText: "Search YouTube...",
          border: InputBorder.none,
          hintStyle: TextStyle(color: Colors.white30),
        ),
        textInputAction: TextInputAction.go,
        style: TextStyle(color: Colors.white, fontSize: 16.0),
        onSubmitted: (query) => updateSearchQuery(query),
      );
    } else if (_isChannelView || _isPlaylistView) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            leadingContext,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      );
    } else {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("jidoujisho"),
          Text(
            " $version beta",
            style: TextStyle(
              fontWeight: FontWeight.w200,
              fontSize: 12,
            ),
          ),
        ],
      );
    }
  }

  Widget _buildChannels() {
    Widget centerMessage(String text, IconData icon) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              color: Colors.grey,
              size: 72,
            ),
            const SizedBox(height: 6),
            Text(
              text,
              style: TextStyle(
                color: Colors.grey,
                fontSize: 20,
              ),
            )
          ],
        ),
      );
    }

    Widget queryMessage = centerMessage(
      "Listing channels...",
      Icons.subscriptions_sharp,
    );
    Widget errorMessage = centerMessage(
      "Error getting channels",
      Icons.error,
    );
    Widget videoMessage = centerMessage(
      "Listing recent videos...",
      Icons.subscriptions_sharp,
    );

    if (_isChannelView && searchQuery != null) {
      return FutureBuilder(
        future: fetchChannelVideoCache(searchQuery),
        builder: (BuildContext context, AsyncSnapshot<dynamic> snapshot) {
          var results = snapshot.data;

          switch (snapshot.connectionState) {
            case ConnectionState.waiting:
            case ConnectionState.none:
              return videoMessage;
              break;
            default:
              if (!snapshot.hasData) {
                return errorMessage;
              }
              return ListView.builder(
                addAutomaticKeepAlives: true,
                itemCount: snapshot.data.length,
                itemBuilder: (BuildContext context, int index) {
                  Video result = results[index];
                  print("VIDEO LISTED: $result");

                  return YouTubeResult(
                    result,
                    captioningCache[result.id],
                    fetchCaptioningCache(result.id.value),
                    fetchMetadataCache(result.id.value, result),
                    index,
                  );
                },
              );
          }
        },
      );
    } else {
      return FutureBuilder(
        future: fetchChannelCache(),
        builder: (BuildContext context, AsyncSnapshot<dynamic> snapshot) {
          var results = snapshot.data;

          switch (snapshot.connectionState) {
            case ConnectionState.waiting:
            case ConnectionState.none:
              return queryMessage;
            default:
              if (!snapshot.hasData) {
                return errorMessage;
              }
              return ListView.builder(
                addAutomaticKeepAlives: true,
                itemCount: snapshot.data.length + 1,
                itemBuilder: (BuildContext context, int index) {
                  if (index == 0) {
                    return _buildNewChannelRow();
                  }

                  Channel result = results[index - 1];
                  print("CHANNEL LISTED: $result");

                  return ChannelResult(
                    result,
                    setChannelVideoSearch,
                    setStateFromResult,
                    index,
                  );
                },
              );
          }
        },
      );
    }
  }

  Widget _buildPlaylists() {
    Widget centerMessage(String text, IconData icon) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              color: Colors.grey,
              size: 72,
            ),
            const SizedBox(height: 6),
            Text(
              text,
              style: TextStyle(
                color: Colors.grey,
                fontSize: 20,
              ),
            )
          ],
        ),
      );
    }

    Widget queryMessage = centerMessage(
      "Listing channels...",
      Icons.subscriptions_sharp,
    );
    Widget errorMessage = centerMessage(
      "Error getting channels",
      Icons.error,
    );
    Widget videoMessage = centerMessage(
      "Listing recent videos...",
      Icons.subscriptions_sharp,
    );

    if (_isChannelView && searchQuery != null) {
      return FutureBuilder(
        future: fetchChannelVideoCache(searchQuery),
        builder: (BuildContext context, AsyncSnapshot<dynamic> snapshot) {
          var results = snapshot.data;

          switch (snapshot.connectionState) {
            case ConnectionState.waiting:
            case ConnectionState.none:
              return videoMessage;
              break;
            default:
              if (!snapshot.hasData) {
                return errorMessage;
              }
              return ListView.builder(
                addAutomaticKeepAlives: true,
                itemCount: snapshot.data.length,
                itemBuilder: (BuildContext context, int index) {
                  Video result = results[index];
                  print("VIDEO LISTED: $result");

                  return YouTubeResult(
                    result,
                    captioningCache[result.id],
                    fetchCaptioningCache(result.id.value),
                    fetchMetadataCache(result.id.value, result),
                    index,
                  );
                },
              );
          }
        },
      );
    } else {
      return FutureBuilder(
        future: fetchChannelCache(),
        builder: (BuildContext context, AsyncSnapshot<dynamic> snapshot) {
          var results = snapshot.data;

          switch (snapshot.connectionState) {
            case ConnectionState.waiting:
            case ConnectionState.none:
              return queryMessage;
            default:
              if (!snapshot.hasData) {
                return errorMessage;
              }
              return ListView.builder(
                addAutomaticKeepAlives: true,
                itemCount: snapshot.data.length + 1,
                itemBuilder: (BuildContext context, int index) {
                  if (index == 0) {
                    return _buildNewChannelRow();
                  }

                  Channel result = results[index - 1];
                  print("CHANNEL LISTED: $result");

                  return ChannelResult(
                    result,
                    setChannelVideoSearch,
                    setStateFromResult,
                    index,
                  );
                },
              );
          }
        },
      );
    }
  }

  void setStateFromResult() {
    setState(() {});
  }

  Widget _buildNewChannelRow() {
    String channelLogoURL = "";
    String channelTitle = "List new channel";

    Widget displayThumbnail() {
      return ClipRRect(
        borderRadius: BorderRadius.circular(25.0),
        child: Container(
          alignment: Alignment.center,
          height: 36,
          width: 36,
          color: Colors.grey[900],
          child: Icon(
            Icons.add,
            color: Colors.grey,
            size: 16,
          ),
        ),
      );
    }

    Widget displayVideoInformation() {
      return Expanded(
        child: Container(
          padding: EdgeInsets.only(left: 12, right: 6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                channelTitle,
                style: TextStyle(color: Colors.grey),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      );
    }

    return InkWell(
      onTap: () {
        TextEditingController _textFieldController = TextEditingController();

        showDialog(
          context: context,
          builder: (context) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.zero,
              ),
              content: TextField(
                controller: _textFieldController,
                decoration: InputDecoration(
                    hintText: "Enter link to any video by channel"),
              ),
              actions: <Widget>[
                TextButton(
                  child: Text('CANCEL', style: TextStyle(color: Colors.white)),
                  onPressed: () {
                    Navigator.pop(context);
                  },
                ),
                TextButton(
                  child: Text('OK', style: TextStyle(color: Colors.white)),
                  onPressed: () async {
                    String _input = _textFieldController.text;
                    await addNewChannel(_input);

                    setState(() {});
                    Navigator.pop(context);
                  },
                ),
              ],
            );
          },
        );
      },
      child: Container(
        padding: EdgeInsets.only(left: 16, right: 16),
        height: 48,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            displayThumbnail(),
            displayVideoInformation(),
          ],
        ),
      ),
    );
  }

  void setChannelVideoSearch(String channelID, String channelName) {
    setState(() {
      _isChannelView = true;
      searchQuery = channelID;
      leadingContext = channelName;
    });
  }

  Widget _buildBody() {
    Widget centerMessage(String text, IconData icon) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              color: Colors.grey,
              size: 72,
            ),
            const SizedBox(height: 6),
            Text(
              text,
              style: TextStyle(
                color: Colors.grey,
                fontSize: 20,
              ),
            )
          ],
        ),
      );
    }

    Widget searchMessage = centerMessage(
      "Enter keyword to search",
      Icons.youtube_searched_for,
    );
    Widget searchingMessage = centerMessage(
      "Searching for \"$searchQuery\"...",
      Icons.youtube_searched_for,
    );
    Widget queryMessage = centerMessage(
      "Querying trending videos...",
      Icons.youtube_searched_for,
    );
    Widget errorMessage = centerMessage(
      "Error getting videos",
      Icons.error,
    );
    Widget featureLockedMessage = ColorFiltered(
      child: Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FadeInImage(
                image: AssetImage("assets/icon/icon.png"),
                placeholder: MemoryImage(kTransparentImage),
                height: 72,
                fit: BoxFit.fitHeight,
              ),
              const SizedBox(height: 6),
              Text(
                "A video player for language learners",
                style: TextStyle(
                  color: Colors.grey,
                  fontSize: 20,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                "GETTING STARTED\n📲 Play a local media file with the lower right button to get started\n" +
                    "⏯️  Select subtitles by simply holding and drag to change selection\n" +
                    "📋 When the dictionary definition for the text shows up, the text is the current context\n" +
                    "📔 Closing the dictionary prompt will clear the clipboard\n" +
                    "🗑️ The current context may be used to open browser links to third-party websites\n" +
                    "🌐 You may swipe vertically to open the transcript, and you can pick a time or read subtitles\n" +
                    "↔️ Swipe horizontally to repeat the current subtitle audio\n\n" +
                    "EXPORTING TO ANKIDROID\n📤 You may also export the current context to an AnkiDroid card, including the current frame and audio\n" +
                    "🔤 Having a word in the clipboard will include the sentence, word, meaning and reading in the export\n" +
                    "📝 You may edit the sentence, word, meaning and reading text fields before sharing to AnkiDroid\n" +
                    "🔗 To finalise the export, share the exported text to AnkiDroid\n" +
                    "🃏 The front of the card will include the audio, video and sentence\n" +
                    "🎴 The back of the card will include the reading, word and meaning\n" +
                    "📑 You may apply text formatting to the card with the AnkiDroid editor once shared\n"
                        "⚛️ Extensive customisation of the Anki export is planned",
                style: TextStyle(
                  color: Colors.grey,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
      colorFilter: ColorFilter.mode(Colors.black, BlendMode.saturation),
    );

    if (_isSearching && searchQuery == "") {
      return searchMessage;
    }

    if (isGooglePlayLimited) {
      return featureLockedMessage;
    }

    return FutureBuilder(
      future: _isSearching && searchQuery != ""
          ? fetchSearchCache(searchQuery)
          : fetchTrendingCache(),
      builder: (BuildContext context, AsyncSnapshot<dynamic> snapshot) {
        var results = snapshot.data;

        switch (snapshot.connectionState) {
          case ConnectionState.waiting:
            if (_isSearching && searchQuery != "") {
              return searchingMessage;
            } else if (_isSearching && searchQuery != "") {
              return searchMessage;
            } else {
              return queryMessage;
            }
            break;
          default:
            if (!snapshot.hasData) {
              return errorMessage;
            }
            return ListView.builder(
              addAutomaticKeepAlives: true,
              itemCount: snapshot.data.length,
              itemBuilder: (BuildContext context, int index) {
                Video result = results[index];
                print("VIDEO LISTED: $result");

                return YouTubeResult(
                  result,
                  captioningCache[result.id],
                  fetchCaptioningCache(result.id.value),
                  fetchMetadataCache(result.id.value, result),
                  index,
                );
              },
            );
        }
      },
    );
  }

  _showPopupMenu(Offset offset) async {
    double left = offset.dx;
    double top = offset.dy;
    String option = await showMenu(
      color: Colors.grey[900],
      context: context,
      position: RelativeRect.fromLTRB(left, top, 0, 0),
      items: isGooglePlayLimited
          ? [
              PopupMenuItem<String>(
                  child: const Text('View on GitHub'), value: 'View on GitHub'),
              PopupMenuItem<String>(
                  child: const Text('Report a bug'), value: 'Report a bug'),
              PopupMenuItem<String>(
                  child: const Text('About this app'), value: 'About this app'),
            ]
          : [
              PopupMenuItem<String>(
                  child: const Text('Enter YouTube URL'),
                  value: 'Enter YouTube URL'),
              PopupMenuItem<String>(
                  child: const Text('View on GitHub'), value: 'View on GitHub'),
              PopupMenuItem<String>(
                  child: const Text('Report a bug'), value: 'Report a bug'),
              PopupMenuItem<String>(
                  child: const Text('About this app'), value: 'About this app'),
            ],
      elevation: 8.0,
    );

    switch (option) {
      case "Enter YouTube URL":
        TextEditingController _textFieldController = TextEditingController();

        showDialog(
          context: context,
          builder: (context) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.zero,
              ),
              content: TextField(
                controller: _textFieldController,
                decoration: InputDecoration(hintText: "Enter YouTube URL"),
              ),
              actions: <Widget>[
                TextButton(
                  child: Text('CANCEL', style: TextStyle(color: Colors.white)),
                  onPressed: () {
                    Navigator.pop(context);
                  },
                ),
                TextButton(
                  child: Text('OK', style: TextStyle(color: Colors.white)),
                  onPressed: () {
                    String _webURL = _textFieldController.text;

                    try {
                      if (YoutubePlayer.convertUrlToId(_webURL) != null) {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => Player(
                              url: _webURL,
                              initialPosition: -1,
                            ),
                          ),
                        ).then((returnValue) {
                          setState(() {
                            SystemChrome.setPreferredOrientations([
                              DeviceOrientation.portraitUp,
                              DeviceOrientation.landscapeLeft,
                              DeviceOrientation.landscapeRight,
                            ]);
                          });

                          globalPrefs.setString("lastPlayedPath", _webURL);
                          globalPrefs.setInt("lastPlayedPosition", 0);
                          globalResumable.value = true;
                        });
                      }
                    } on Exception {
                      Navigator.pop(context);
                      print("INVALID LINK");
                    } catch (error) {
                      Navigator.pop(context);
                      print("INVALID LINK");
                    }
                  },
                ),
              ],
            );
          },
        );
        break;
      case "View on GitHub":
        await launch("https://github.com/lrorpilla/jidoujisho");
        break;
      case "Report a bug":
        await launch("https://github.com/lrorpilla/jidoujisho/issues/new");
        break;
      case "About this app":
        const String legalese = "A video player for language learners.\n\n" +
            "Built for the Japanese language learning community by Leo " +
            "Rafael Orpilla. Word definitions queried from Jisho.org. Logo " +
            "by Aaron Marbella.\n\nIf you like my work, you can help me out " +
            "by providing feedback, making a donation, reporting issues or " +
            "collaborating with me on further improvements on GitHub.";

        showLicensePage(
          context: context,
          applicationName: "jidoujisho",
          applicationIcon: Padding(
            padding: EdgeInsets.only(top: 8, bottom: 8),
            child: Image(
              image: AssetImage("assets/icon/icon.png"),
              height: 48,
              width: 48,
            ),
          ),
          applicationVersion: version,
          applicationLegalese: legalese,
        );
        break;
    }
  }

  Widget _buildResume() {
    return ValueListenableBuilder(
      valueListenable: globalResumable,
      builder: (_, __, ___) {
        if (globalResumable.value) {
          return IconButton(
            icon: const Icon(Icons.restore),
            onPressed: () async {
              int lastPlayedPosition =
                  globalPrefs.getInt("lastPlayedPosition") ?? 0;
              String globalLastPlayedPath =
                  globalPrefs.getString("lastPlayedPath") ?? "-1";

              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => Player(
                    url: globalLastPlayedPath,
                    initialPosition: lastPlayedPosition,
                  ),
                ),
              ).then((returnValue) {
                SystemChrome.setPreferredOrientations([
                  DeviceOrientation.portraitUp,
                  DeviceOrientation.landscapeLeft,
                  DeviceOrientation.landscapeRight,
                ]);
              });
            },
          );
        } else {
          return IconButton(
            icon: Icon(
              Icons.restore,
              color: Colors.grey[800],
            ),
          );
        }
      },
    );
  }

  List<Widget> _buildActions() {
    if (_isSearching) {
      return <Widget>[
        _buildResume(),
        IconButton(
          icon: const Icon(Icons.clear),
          onPressed: () {
            _clearSearchQuery();
          },
        ),
        const SizedBox(width: 12),
        GestureDetector(
          child: const Icon(Icons.more_vert),
          onTapDown: (TapDownDetails details) {
            _showPopupMenu(details.globalPosition);
          },
        ),
        const SizedBox(width: 12),
      ];
    }

    return <Widget>[
      _buildResume(),
      isGooglePlayLimited
          ? Container()
          : IconButton(
              icon: const Icon(Icons.search),
              onPressed: _startSearch,
            ),
      const SizedBox(width: 12),
      GestureDetector(
        child: const Icon(Icons.more_vert),
        onTapDown: (TapDownDetails details) {
          _showPopupMenu(details.globalPosition);
        },
      ),
      const SizedBox(width: 12),
    ];
  }

  void _startSearch() {
    ModalRoute.of(context)
        .addLocalHistoryEntry(LocalHistoryEntry(onRemove: _stopSearching));
    searchQuery = "";

    setState(() {
      _isSearching = true;
    });
  }

  void updateSearchQuery(String newQuery) {
    setState(() {
      searchQuery = newQuery;
    });
  }

  void _stopSearching() {
    _clearSearchQuery();

    setState(() {
      _isSearching = false;
    });
  }

  void _clearSearchQuery() {
    setState(() {
      _searchQueryController.clear();
      updateSearchQuery("");
    });
  }
}

class YouTubeResult extends StatefulWidget {
  final Video result;
  final AsyncMemoizer cache;
  final cacheCallback;
  final metadataCallback;
  final int index;

  YouTubeResult(
    this.result,
    this.cache,
    this.cacheCallback,
    this.metadataCallback,
    this.index,
  );

  _YouTubeResultState createState() => _YouTubeResultState(
        this.result,
        this.cache,
        this.cacheCallback,
        this.metadataCallback,
        this.index,
      );
}

class _YouTubeResultState extends State<YouTubeResult>
    with AutomaticKeepAliveClientMixin {
  final Video result;
  final AsyncMemoizer cache;
  final cacheCallback;
  final metadataCallback;
  final int index;

  _YouTubeResultState(
    this.result,
    this.cache,
    this.cacheCallback,
    this.metadataCallback,
    this.index,
  );

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);

    String videoStreamURL = result.url;
    String videoThumbnailURL = result.thumbnails.highResUrl;

    String videoTitle = result.title;
    String videoChannel = result.author;
    String videoPublishTime =
        result.uploadDate == null ? "" : getTimeAgoFormatted(result.uploadDate);
    String videoViewCount = getViewCountFormatted(result.engagement.viewCount);
    String videoDetails = "$videoPublishTime · $videoViewCount views";
    String videoDuration =
        result.duration == null ? "" : getYouTubeDuration(result.duration);

    Widget displayThumbnail() {
      return Stack(
        alignment: Alignment.bottomRight,
        children: [
          AspectRatio(
            aspectRatio: 4 / 3,
            child: FadeInImage(
              image: NetworkImage(videoThumbnailURL),
              placeholder: MemoryImage(kTransparentImage),
              height: 480,
              fit: BoxFit.fitHeight,
            ),
          ),
          Positioned(
            right: 5.0,
            bottom: 20.0,
            child: Container(
              height: 20,
              color: Colors.black.withOpacity(0.8),
              alignment: Alignment.center,
              child: Text(
                videoDuration,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w300,
                ),
              ),
            ),
          ),
        ],
      );
    }

    Widget displayVideoInformation() {
      return Expanded(
        child: Container(
          padding: EdgeInsets.only(left: 12, right: 6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                videoTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              Text(
                videoChannel,
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: TextStyle(
                  color: Colors.grey,
                  fontSize: 12,
                ),
              ),
              showVideoPublishStatus(
                context,
                result.id.value,
                index,
              ),
              showClosedCaptionStatus(
                context,
                result.id.value,
                index,
              ),
            ],
          ),
        ),
      );
    }

    void playVideo() {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => Player(
            url: videoStreamURL,
            initialPosition: -1,
          ),
        ),
      ).then((returnValue) {
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);

        globalPrefs.setString("lastPlayedPath", videoStreamURL);
        globalPrefs.setInt("lastPlayedPosition", 0);
        globalResumable.value = true;
      });
    }

    return GestureDetector(
      onLongPress: () {
        showDialog(
          context: context,
          builder: (context) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.zero,
              ),
              title: Text(
                result.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              content: AspectRatio(
                aspectRatio: 16 / 9,
                child: FadeInImage(
                  image: NetworkImage(result.thumbnails.highResUrl),
                  placeholder: MemoryImage(kTransparentImage),
                  width: 1280,
                  fit: BoxFit.fitWidth,
                ),
              ),
              actions: <Widget>[
                TextButton(
                  child: Text('CANCEL', style: TextStyle(color: Colors.white)),
                  onPressed: () {
                    Navigator.pop(context);
                  },
                ),
                TextButton(
                  child: Text('LIST CHANNEL',
                      style: TextStyle(color: Colors.white)),
                  onPressed: () async {
                    await addNewChannel(videoStreamURL);
                    Navigator.pop(context);
                  },
                ),
                TextButton(
                  child:
                      Text('PLAY VIDEO', style: TextStyle(color: Colors.white)),
                  onPressed: () async {
                    playVideo();
                    Navigator.pop(context);
                  },
                ),
              ],
            );
          },
        );
      },
      onTap: () {
        playVideo();
      },
      child: Container(
        height: 128,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            displayThumbnail(),
            displayVideoInformation(),
          ],
        ),
      ),
    );
  }

  FutureBuilder showVideoPublishStatus(
    BuildContext context,
    String videoID,
    int index,
  ) {
    Widget metadataRow(String text, Color color) {
      return Text(
        text,
        style: TextStyle(
          color: Colors.grey,
          fontSize: 12,
        ),
        maxLines: 1,
        overflow: TextOverflow.clip,
      );
    }

    Widget queryMessage = metadataRow(
      "Waiting for engagement metrics...",
      Colors.grey,
    );
    Widget errorMessage = metadataRow(
      "Error querying video metadata",
      Colors.grey,
    );

    return FutureBuilder(
      future: metadataCallback,
      builder: (BuildContext context, AsyncSnapshot<dynamic> snapshot) {
        if (snapshot.connectionState == ConnectionState.done) {
          String videoDetails = snapshot.data;
          if (!snapshot.hasData) {
            return errorMessage;
          } else {
            return Text(
              videoDetails,
              style: TextStyle(
                color: Colors.grey,
                fontSize: 12,
              ),
              maxLines: 1,
              overflow: TextOverflow.clip,
            );
          }
        } else {
          return queryMessage;
        }
      },
    );
  }

  FutureBuilder showClosedCaptionStatus(
    BuildContext context,
    String videoID,
    int index,
  ) {
    Widget closedCaptionRow(String text, Color color, IconData icon) {
      return Row(
        children: [
          Icon(
            icon,
            color: color,
            size: 12,
          ),
          const SizedBox(width: 3),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 1,
            overflow: TextOverflow.clip,
          )
        ],
      );
    }

    Widget queryMessage = closedCaptionRow(
      "Querying for closed captions...",
      Colors.grey,
      Icons.youtube_searched_for,
    );
    Widget errorMessage = closedCaptionRow(
      "Error querying closed captions",
      Colors.grey,
      Icons.error,
    );
    Widget availableMessage = closedCaptionRow(
      "Closed captioning available",
      Colors.green[200],
      Icons.closed_caption,
    );
    Widget unavailableMessage = closedCaptionRow(
      "No closed captioning",
      Colors.red[200],
      Icons.closed_caption_disabled,
    );

    return FutureBuilder(
      future: cacheCallback,
      builder: (BuildContext context, AsyncSnapshot<dynamic> snapshot) {
        if (snapshot.connectionState == ConnectionState.done) {
          if (!snapshot.hasData) {
            return errorMessage;
          } else {
            bool hasClosedCaptions = snapshot.data;
            if (hasClosedCaptions) {
              return availableMessage;
            } else {
              return unavailableMessage;
            }
          }
        } else {
          return queryMessage;
        }
      },
    );
  }
}

class ChannelResult extends StatefulWidget {
  final Channel result;
  final SearchCallback callback;
  final VoidCallback stateCallback;
  final int index;

  ChannelResult(
    this.result,
    this.callback,
    this.stateCallback,
    this.index,
  );

  _ChannelResultState createState() => _ChannelResultState(
        this.result,
        this.callback,
        this.stateCallback,
        this.index,
      );
}

class _ChannelResultState extends State<ChannelResult>
    with AutomaticKeepAliveClientMixin {
  final Channel result;
  final SearchCallback callback;
  final stateCallback;
  final int index;

  _ChannelResultState(
    this.result,
    this.callback,
    this.stateCallback,
    this.index,
  );

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);

    String channelLogoURL = result.logoUrl;
    String channelTitle = result.title;

    Widget displayThumbnail() {
      return Stack(alignment: Alignment.bottomRight, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(25.0),
          child: FadeInImage(
            fit: BoxFit.cover,
            width: 36,
            height: 36,
            placeholder: MemoryImage(kTransparentImage),
            image: NetworkImage(channelLogoURL),
          ),
        ),
      ]);
    }

    Widget displayVideoInformation() {
      return Expanded(
        child: Container(
          padding: EdgeInsets.only(left: 12, right: 6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                channelTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      );
    }

    return InkWell(
      onTap: () {
        callback(result.id.toString(), result.title);
      },
      onLongPress: () {
        showDialog(
          context: context,
          builder: (context) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.zero,
              ),
              title: Text("Unlist \"${result.title}\"?"),
              actions: <Widget>[
                TextButton(
                  child: Text('CANCEL', style: TextStyle(color: Colors.white)),
                  onPressed: () {
                    Navigator.pop(context);
                  },
                ),
                TextButton(
                  child: Text('OK', style: TextStyle(color: Colors.white)),
                  onPressed: () async {
                    await removeChannel(result);

                    stateCallback();
                    Navigator.pop(context);
                  },
                ),
              ],
            );
          },
        );
      },
      child: Container(
        padding: EdgeInsets.only(left: 16, right: 16),
        height: 48,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            displayThumbnail(),
            displayVideoInformation(),
          ],
        ),
      ),
    );
  }
}
