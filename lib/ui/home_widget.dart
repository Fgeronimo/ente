import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/core/event_bus.dart';
import 'package:photos/db/files_db.dart';
import 'package:photos/events/backup_folders_updated_event.dart';
import 'package:photos/events/first_import_succeeded_event.dart';
import 'package:photos/events/local_photos_updated_event.dart';
import 'package:photos/events/permission_granted_event.dart';
import 'package:photos/events/subscription_purchased_event.dart';
import 'package:photos/events/tab_changed_event.dart';
import 'package:photos/events/trigger_logout_event.dart';
import 'package:photos/events/user_logged_out_event.dart';
import 'package:photos/models/filters/important_items_filter.dart';
import 'package:photos/models/file.dart';
import 'package:photos/models/selected_files.dart';
import 'package:photos/services/billing_service.dart';
import 'package:photos/services/sync_service.dart';
import 'package:photos/ui/backup_folder_selection_widget.dart';
import 'package:photos/ui/collections_gallery_widget.dart';
import 'package:photos/ui/extents_page_view.dart';
import 'package:photos/ui/gallery.dart';
import 'package:photos/ui/grant_permissions_widget.dart';
import 'package:photos/ui/loading_photos_widget.dart';
import 'package:photos/ui/memories_widget.dart';
import 'package:photos/services/user_service.dart';
import 'package:photos/ui/nav_bar.dart';
import 'package:photos/ui/settings_button.dart';
import 'package:photos/ui/shared_collections_gallery.dart';
import 'package:logging/logging.dart';
import 'package:photos/ui/sign_in_header_widget.dart';
import 'package:photos/ui/sync_indicator.dart';
import 'package:photos/utils/dialog_util.dart';
import 'package:uni_links/uni_links.dart';

class HomeWidget extends StatefulWidget {
  const HomeWidget({Key key}) : super(key: key);

  @override
  State<StatefulWidget> createState() => _HomeWidgetState();
}

class _HomeWidgetState extends State<HomeWidget> {
  final _logger = Logger("HomeWidgetState");
  final _deviceFolderGalleryWidget = CollectionsGalleryWidget();
  final _sharedCollectionGallery = SharedCollectionGallery();
  final _selectedFiles = SelectedFiles();
  final _settingsButton = SettingsButton();
  static const _headerWidget = HeaderWidget();
  final PageController _pageController = PageController();
  int _selectedTabIndex = 0;
  Widget _headerWidgetWithSettingsButton;

  StreamSubscription<TabChangedEvent> _tabChangedEventSubscription;
  StreamSubscription<PermissionGrantedEvent> _permissionGrantedEvent;
  StreamSubscription<SubscriptionPurchasedEvent> _subscriptionPurchaseEvent;
  StreamSubscription<FirstImportSucceededEvent> _firstImportEvent;
  StreamSubscription<TriggerLogoutEvent> _triggerLogoutEvent;
  StreamSubscription<UserLoggedOutEvent> _loggedOutEvent;
  StreamSubscription<BackupFoldersUpdatedEvent> _backupFoldersUpdatedEvent;

  @override
  void initState() {
    _logger.info("Building initstate");
    _headerWidgetWithSettingsButton = Container(
      margin: const EdgeInsets.only(top: 12),
      child: Stack(
        children: [
          _headerWidget,
          _settingsButton,
        ],
      ),
    );
    _tabChangedEventSubscription =
        Bus.instance.on<TabChangedEvent>().listen((event) {
      if (event.source != TabChangedEventSource.tab_bar) {
        setState(() {
          _selectedTabIndex = event.selectedIndex;
        });
      }
      if (event.source != TabChangedEventSource.page_view) {
        _pageController.animateToPage(
          event.selectedIndex,
          duration: Duration(milliseconds: 150),
          curve: Curves.easeIn,
        );
      }
    });
    _permissionGrantedEvent =
        Bus.instance.on<PermissionGrantedEvent>().listen((event) {
      setState(() {});
    });
    _subscriptionPurchaseEvent =
        Bus.instance.on<SubscriptionPurchasedEvent>().listen((event) {
      setState(() {});
      if (Configuration.instance.getPathsToBackUp().isEmpty) {
        _showBackupFolderSelectionDialog();
      }
    });
    _firstImportEvent =
        Bus.instance.on<FirstImportSucceededEvent>().listen((event) {
      setState(() {});
    });
    _triggerLogoutEvent =
        Bus.instance.on<TriggerLogoutEvent>().listen((event) async {
      AlertDialog alert = AlertDialog(
        title: Text("session expired"),
        content: Text("please login again"),
        actions: [
          TextButton(
            child: Text(
              "ok",
              style: TextStyle(
                color: Theme.of(context).buttonColor,
              ),
            ),
            onPressed: () async {
              Navigator.of(context, rootNavigator: true).pop('dialog');
              final dialog = createProgressDialog(context, "logging out...");
              await dialog.show();
              await Configuration.instance.logout();
              await dialog.hide();
            },
          ),
        ],
      );

      showDialog(
        context: context,
        builder: (BuildContext context) {
          return alert;
        },
      );
    });
    _loggedOutEvent = Bus.instance.on<UserLoggedOutEvent>().listen((event) {
      setState(() {});
    });
    _backupFoldersUpdatedEvent =
        Bus.instance.on<BackupFoldersUpdatedEvent>().listen((event) {
      setState(() {});
    });
    _initDeepLinks();
    if (Configuration.instance.getPathsToBackUp().isEmpty &&
        Configuration.instance.hasConfiguredAccount() &&
        BillingService.instance.hasActiveSubscription()) {
      _showBackupFolderSelectionDialog();
    }
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    _logger.info("Building home_Widget");

    return Scaffold(
      appBar: PreferredSize(
        preferredSize: Size.fromHeight(0),
        child: Container(),
      ),
      body: Stack(
        children: [
          ExtentsPageView(
            children: [
              SyncService.instance.hasGrantedPermissions()
                  ? (SyncService.instance.hasScannedDisk()
                      ? _getMainGalleryWidget()
                      : const LoadingPhotosWidget())
                  : GrantPermissionsWidget(),
              _deviceFolderGalleryWidget,
              _sharedCollectionGallery,
            ],
            onPageChanged: (page) {
              Bus.instance.fire(TabChangedEvent(
                page,
                TabChangedEventSource.page_view,
              ));
            },
            controller: _pageController,
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: _buildBottomNavigationBar(),
          ),
        ],
      ),
    );
  }

  Future<bool> _initDeepLinks() async {
    // Platform messages may fail, so we use a try/catch PlatformException.
    try {
      String initialLink = await getInitialLink();
      // Parse the link and warn the user, if it is not correct,
      // but keep in mind it could be `null`.
      if (initialLink != null) {
        _logger.info("Initial link received: " + initialLink);
        _getCredentials(context, initialLink);
        return true;
      } else {
        _logger.info("No initial link received.");
      }
    } on PlatformException {
      // Handle exception by warning the user their action did not succeed
      // return?
      _logger.severe("PlatformException thrown while getting initial link");
    }

    // Attach a listener to the stream
    getLinksStream().listen((String link) {
      _logger.info("Link received: " + link);
      _getCredentials(context, link);
    }, onError: (err) {
      _logger.severe(err);
    });
    return false;
  }

  void _getCredentials(BuildContext context, String link) {
    if (Configuration.instance.hasConfiguredAccount()) {
      return;
    }
    final ott = Uri.parse(link).queryParameters["ott"];
    UserService.instance.getCredentials(context, ott);
  }

  Widget _getMainGalleryWidget() {
    var header;
    if (_selectedFiles.files.isEmpty) {
      header = _headerWidgetWithSettingsButton;
    } else {
      header = _headerWidget;
    }
    return Gallery(
      asyncLoader: (creationStartTime, creationEndTime, {limit}) {
        return FilesDB.instance
            .getFiles(creationStartTime, creationEndTime, limit: limit);
      },
      reloadEvent: Bus.instance.on<LocalPhotosUpdatedEvent>(),
      tagPrefix: "home_gallery",
      selectedFiles: _selectedFiles,
      headerWidget: header,
      isHomePageGallery: true,
    );
  }

  Widget _buildBottomNavigationBar() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.90),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 15.0, vertical: 8),
          child: GNav(
              rippleColor: Theme.of(context).buttonColor.withOpacity(0.20),
              hoverColor: Theme.of(context).buttonColor.withOpacity(0.20),
              gap: 8,
              activeColor: Theme.of(context).buttonColor.withOpacity(0.75),
              iconSize: 24,
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              duration: Duration(milliseconds: 400),
              tabMargin: EdgeInsets.only(left: 8, right: 8),
              tabBackgroundColor:
                  Theme.of(context).appBarTheme.color.withOpacity(0.7),
              haptic: false,
              tabs: [
                GButton(
                  icon: Icons.photo_library_outlined,
                  text: 'photos',
                ),
                GButton(
                  icon: Icons.folder_special_outlined,
                  text: 'albums',
                ),
                GButton(
                  icon: Icons.folder_shared_outlined,
                  text: 'shared',
                ),
              ],
              selectedIndex: _selectedTabIndex,
              onTabChange: (index) {
                setState(() {
                  Bus.instance.fire(TabChangedEvent(
                    index,
                    TabChangedEventSource.tab_bar,
                  ));
                });
              }),
        ),
      ),
    );
  }

  List<File> _getFilteredPhotos(List<File> unfilteredFiles) {
    _logger.info("Filtering " + unfilteredFiles.length.toString());
    final List<File> filteredPhotos = List<File>();
    final filter = ImportantItemsFilter();
    for (File file in unfilteredFiles) {
      if (filter.shouldInclude(file)) {
        filteredPhotos.add(file);
      }
    }
    _logger.info("Filtered down to " + filteredPhotos.length.toString());
    return filteredPhotos;
  }

  void _showBackupFolderSelectionDialog() {
    Future.delayed(
      Duration.zero,
      () => showDialog(
        context: context,
        builder: (context) {
          return WillPopScope(
            onWillPop: () async => false,
            child: AlertDialog(
              content: const BackupFolderSelectionWidget("start backup"),
              backgroundColor: Colors.black.withOpacity(0.8),
            ),
          );
        },
        barrierDismissible: false,
        barrierColor: Colors.black.withOpacity(0.85),
      ),
    );
  }

  @override
  void dispose() {
    _tabChangedEventSubscription.cancel();
    _permissionGrantedEvent.cancel();
    _subscriptionPurchaseEvent.cancel();
    _firstImportEvent.cancel();
    _triggerLogoutEvent.cancel();
    _loggedOutEvent.cancel();
    _backupFoldersUpdatedEvent.cancel();
    super.dispose();
  }
}

class HeaderWidget extends StatelessWidget {
  static const _memoriesWidget = const MemoriesWidget();
  static const _signInHeader = const SignInHeader();
  static const _syncIndicator = const SyncIndicator();

  const HeaderWidget({
    Key key,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    Logger("Header").info("Building header widget");
    const list = [
      _signInHeader,
      _syncIndicator,
      _memoriesWidget,
    ];
    return Column(
      children: list,
      crossAxisAlignment: CrossAxisAlignment.start,
    );
  }
}
