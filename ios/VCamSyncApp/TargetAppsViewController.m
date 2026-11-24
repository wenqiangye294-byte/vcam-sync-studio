#import "TargetAppsViewController.h"
#import "AppContainerMirror.h"
#import "SyncManager.h"

@interface TargetAppsViewController () <UISearchResultsUpdating>
@property (nonatomic, strong) NSArray<VCamInstalledApp *> *allApps;
@property (nonatomic, strong) NSArray<VCamInstalledApp *> *filteredApps;
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedIDs;
@property (nonatomic, strong) UISearchController *searchController;
@end

@implementation TargetAppsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择目标 App（巨魔镜像）";

    self.allApps = [[AppContainerMirror sharedMirror] discoverInstalledUserApps];
    self.filteredApps = self.allApps;
    self.selectedIDs = [NSMutableSet setWithArray:[[AppContainerMirror sharedMirror] selectedBundleIDs]];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"保存并同步"
                                                                              style:UIBarButtonItemStyleDone
                                                                             target:self
                                                                             action:@selector(onSave)];

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"搜索 App 名称或 Bundle ID";
    self.navigationItem.searchController = self.searchController;
    self.definesPresentationContext = YES;
}

- (void)onSave {
    [[AppContainerMirror sharedMirror] saveSelectedBundleIDs:self.selectedIDs.allObjects];
    NSError *err = nil;
    NSArray *mirrored = [[AppContainerMirror sharedMirror] mirrorMasterStoreToSelectedAppsError:&err];
    [[SyncManager sharedManager] notifyTargetAppsUpdated];

    NSString *msg = [NSString stringWithFormat:@"已向 %lu 个目标 App 写入同步目录。", (unsigned long)mirrored.count];
    if (err) {
        msg = [msg stringByAppendingFormat:@"\n部分目录权限警告：%@", err.localizedDescription];
    }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"镜像完成"
                                                                message:msg
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        (void)action;
        if (self.onSelectionSaved) self.onSelectionSaved();
        [self.navigationController popViewControllerAnimated:YES];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *q = [searchController.searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].lowercaseString;
    if (q.length == 0) {
        self.filteredApps = self.allApps;
    } else {
        NSPredicate *pred = [NSPredicate predicateWithBlock:^BOOL(VCamInstalledApp *app, NSDictionary *bindings) {
            (void)bindings;
            return [app.displayName.lowercaseString containsString:q] || [app.bundleID.lowercaseString containsString:q];
        }];
        self.filteredApps = [self.allApps filteredArrayUsingPredicate:pred];
    }
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return (NSInteger)self.filteredApps.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return @"勾选在 TrollFools 中注入了 VCamHook.dylib 的 App（越狱环境全局生效，也可勾选备用）";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"AppCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"AppCell"];
    }
    VCamInstalledApp *app = self.filteredApps[(NSUInteger)indexPath.row];
    cell.textLabel.text = app.displayName;
    cell.detailTextLabel.text = app.bundleID;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.accessoryType = [self.selectedIDs containsObject:app.bundleID]
        ? UITableViewCellAccessoryCheckmark
        : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    VCamInstalledApp *app = self.filteredApps[(NSUInteger)indexPath.row];
    if ([self.selectedIDs containsObject:app.bundleID]) {
        [self.selectedIDs removeObject:app.bundleID];
    } else {
        [self.selectedIDs addObject:app.bundleID];
    }
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

@end
