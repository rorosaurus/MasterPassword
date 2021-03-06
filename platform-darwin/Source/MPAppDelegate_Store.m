//==============================================================================
// This file is part of Master Password.
// Copyright (c) 2011-2017, Maarten Billemont.
//
// Master Password is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Master Password is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You can find a copy of the GNU General Public License in the
// LICENSE file.  Alternatively, see <http://www.gnu.org/licenses/>.
//==============================================================================

#import "MPAppDelegate_Store.h"

#if TARGET_OS_IPHONE
#define STORE_OPTIONS NSPersistentStoreFileProtectionKey : NSFileProtectionComplete,
#else
#define STORE_OPTIONS
#endif

#define MPMigrationLevelLocalStoreKey @"MPMigrationLevelLocalStoreKey"

typedef NS_ENUM( NSInteger, MPStoreMigrationLevel ) {
    MPStoreMigrationLevelV1,
    MPStoreMigrationLevelV2,
    MPStoreMigrationLevelV3,
    MPStoreMigrationLevelCurrent = MPStoreMigrationLevelV3,
};

@implementation MPAppDelegate_Shared(Store)

PearlAssociatedObjectProperty( NSOperationQueue *, StoreQueue, storeQueue );

PearlAssociatedObjectProperty( NSManagedObjectContext*, PrivateManagedObjectContext, privateManagedObjectContext );

PearlAssociatedObjectProperty( NSManagedObjectContext*, MainManagedObjectContext, mainManagedObjectContext );

PearlAssociatedObjectProperty( NSNumber*, StoreCorrupted, storeCorrupted );

#pragma mark - Core Data setup

+ (NSManagedObjectContext *)managedObjectContextForMainThreadIfReady {

    NSAssert( [[NSThread currentThread] isMainThread], @"Can only access main MOC from the main thread." );
    NSManagedObjectContext *mainManagedObjectContext = [[self get] mainManagedObjectContextIfReady];
    if (!mainManagedObjectContext || ![[NSThread currentThread] isMainThread])
        return nil;

    return mainManagedObjectContext;
}

+ (BOOL)managedObjectContextForMainThreadPerformBlock:(void ( ^ )(NSManagedObjectContext *mainContext))mocBlock {

    NSManagedObjectContext *mainManagedObjectContext = [[self get] mainManagedObjectContextIfReady];
    if (!mainManagedObjectContext)
        return NO;

    [mainManagedObjectContext performBlock:^{
        @try {
            mocBlock( mainManagedObjectContext );
        }
        @catch (id exception) {
            err( @"While performing managed block:\n%@", [exception fullDescription] );
        }
    }];

    return YES;
}

+ (BOOL)managedObjectContextForMainThreadPerformBlockAndWait:(void ( ^ )(NSManagedObjectContext *mainContext))mocBlock {

    NSManagedObjectContext *mainManagedObjectContext = [[self get] mainManagedObjectContextIfReady];
    if (!mainManagedObjectContext)
        return NO;

    [mainManagedObjectContext performBlockAndWait:^{
        @try {
            mocBlock( mainManagedObjectContext );
        }
        @catch (NSException *exception) {
            err( @"While performing managed block:\n%@", [exception fullDescription] );
        }
    }];

    return YES;
}

+ (BOOL)managedObjectContextPerformBlock:(void ( ^ )(NSManagedObjectContext *context))mocBlock {

    NSManagedObjectContext *privateManagedObjectContextIfReady = [[self get] privateManagedObjectContextIfReady];
    if (!privateManagedObjectContextIfReady)
        return NO;

    NSManagedObjectContext *moc = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    moc.parentContext = privateManagedObjectContextIfReady;
    [moc performBlock:^{
        @try {
            mocBlock( moc );
        }
        @catch (NSException *exception) {
            err( @"While performing managed block:\n%@", [exception fullDescription] );
        }
    }];

    return YES;
}

+ (BOOL)managedObjectContextPerformBlockAndWait:(void ( ^ )(NSManagedObjectContext *context))mocBlock {

    NSManagedObjectContext *privateManagedObjectContextIfReady = [[self get] privateManagedObjectContextIfReady];
    if (!privateManagedObjectContextIfReady)
        return NO;

    NSManagedObjectContext *moc = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    moc.parentContext = privateManagedObjectContextIfReady;
    [moc performBlockAndWait:^{
        @try {
            mocBlock( moc );
        }
        @catch (NSException *exception) {
            err( @"While performing managed block:\n%@", [exception fullDescription] );
        }
    }];

    return YES;
}

- (NSManagedObjectContext *)mainManagedObjectContextIfReady {

    [self loadStore];
    return self.mainManagedObjectContext;
}

- (NSManagedObjectContext *)privateManagedObjectContextIfReady {

    [self loadStore];
    return self.privateManagedObjectContext;
}

- (NSURL *)localStoreURL {

    NSURL *applicationSupportURL = [[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                                           inDomains:NSUserDomainMask] lastObject];
    return [[[applicationSupportURL
            URLByAppendingPathComponent:[NSBundle mainBundle].bundleIdentifier isDirectory:YES]
            URLByAppendingPathComponent:@"MasterPassword" isDirectory:NO]
            URLByAppendingPathExtension:@"sqlite"];
}

- (void)loadStore {

    static dispatch_once_t once = 0;
    dispatch_once( &once, ^{
        (self.storeQueue = [NSOperationQueue new]).maxConcurrentOperationCount = 1;
    } );

    // Do nothing if already fully set up, otherwise (re-)load the store.
    if (self.storeCoordinator && self.mainManagedObjectContext && self.privateManagedObjectContext)
        return;

    [self.storeQueue addOperationWithBlock:^{
        // Do nothing if already fully set up, otherwise (re-)load the store.
        if (self.storeCoordinator && self.mainManagedObjectContext && self.privateManagedObjectContext)
            return;

        // Unregister any existing observers and contexts.
        PearlRemoveNotificationObserversFrom( self.mainManagedObjectContext );
        [self.mainManagedObjectContext performBlockAndWait:^{
            [self.mainManagedObjectContext reset];
            self.mainManagedObjectContext = nil;
        }];
        [self.privateManagedObjectContext performBlockAndWait:^{
            [self.privateManagedObjectContext reset];
            self.privateManagedObjectContext = nil;
        }];

        // Don't load when the store is corrupted.
        if ([self.storeCorrupted boolValue])
            return;

        // Check if migration is necessary.
        [self migrateStore];

        // Install managed object contexts and observers.
        self.privateManagedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
        [self.privateManagedObjectContext performBlockAndWait:^{
            self.privateManagedObjectContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy;
            self.privateManagedObjectContext.persistentStoreCoordinator = self.storeCoordinator;
        }];

        self.mainManagedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
        self.mainManagedObjectContext.parentContext = self.privateManagedObjectContext;

        // When privateManagedObjectContext is saved, import the changes into mainManagedObjectContext.
        PearlAddNotificationObserverTo( self.mainManagedObjectContext, NSManagedObjectContextDidSaveNotification,
                self.privateManagedObjectContext, nil, ^(NSManagedObjectContext *mainManagedObjectContext, NSNotification *note) {
            [mainManagedObjectContext performBlock:^{
                @try {
                    [mainManagedObjectContext mergeChangesFromContextDidSaveNotification:note];
                }
                @catch (NSException *exception) {
                    err( @"While merging changes:\n%@", [exception fullDescription] );
                }
            }];
        } );


        // Create a new store coordinator.
        NSError *error = nil;
        NSURL *localStoreURL = [self localStoreURL];
        if (![[NSFileManager defaultManager] createDirectoryAtURL:[localStoreURL URLByDeletingLastPathComponent]
                                      withIntermediateDirectories:YES attributes:nil error:&error]) {
            err( @"Couldn't create our application support directory: %@", [error fullDescription] );
            return;
        }
        if (![self.storeCoordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:[self localStoreURL]
                                                       options:@{
                                                               NSMigratePersistentStoresAutomaticallyOption: @YES,
                                                               NSInferMappingModelAutomaticallyOption      : @YES,
                                                               STORE_OPTIONS
                                                       } error:&error]) {
            err( @"Failed to open store: %@", [error fullDescription] );
            self.storeCorrupted = @YES;
            [self handleCoordinatorError:error];
            return;
        }
        self.storeCorrupted = @NO;

#if TARGET_OS_IPHONE
        PearlAddNotificationObserver( UIApplicationWillResignActiveNotification, UIApp, [NSOperationQueue mainQueue],
#else
        PearlAddNotificationObserver( NSApplicationWillResignActiveNotification, NSApp, [NSOperationQueue mainQueue],
#endif
                ^(MPAppDelegate_Shared *self, NSNotification *note) {
        [self.mainManagedObjectContext saveToStore];
        } );

        // Perform a data sanity check on the newly loaded store to find and fix any issues.
        if ([[MPConfig get].checkInconsistency boolValue])
            [MPAppDelegate_Shared managedObjectContextPerformBlockAndWait:^(NSManagedObjectContext *context) {
                [self findAndFixInconsistenciesSaveInContext:context];
            }];
    }];
}

- (void)deleteAndResetStore {

    @synchronized (self) {
        // Unregister any existing observers and contexts.
        PearlRemoveNotificationObserversFrom( self.mainManagedObjectContext );
        [self.mainManagedObjectContext performBlockAndWait:^{
            [self.mainManagedObjectContext reset];
            self.mainManagedObjectContext = nil;
        }];
        [self.privateManagedObjectContext performBlockAndWait:^{
            [self.privateManagedObjectContext reset];
            self.privateManagedObjectContext = nil;
        }];
        NSError *error = nil;
        for (NSPersistentStore *store in self.storeCoordinator.persistentStores) {
            if (![self.storeCoordinator removePersistentStore:store error:&error])
                err( @"Couldn't remove persistence store from coordinator: %@", [error fullDescription] );
        }
        if (![[NSFileManager defaultManager] removeItemAtURL:self.localStoreURL error:&error])
            err( @"Couldn't remove persistence store at URL %@: %@", self.localStoreURL, [error fullDescription] );

        [self loadStore];
    }
}

- (MPFixableResult)findAndFixInconsistenciesSaveInContext:(NSManagedObjectContext *)context {

    NSError *error = nil;
    NSFetchRequest *fetchRequest = [NSFetchRequest new];
    fetchRequest.fetchBatchSize = 50;

    MPFixableResult result = MPFixableResultNoProblems;
    for (NSEntityDescription *entity in [context.persistentStoreCoordinator.managedObjectModel entities])
        if (class_conformsToProtocol( NSClassFromString( entity.managedObjectClassName ), @protocol(MPFixable) )) {
            fetchRequest.entity = entity;
            NSArray *objects = [context executeFetchRequest:fetchRequest error:&error];
            if (!objects) {
                err( @"Failed to fetch %@ objects: %@", entity, [error fullDescription] );
                continue;
            }

            for (NSManagedObject<MPFixable> *object in objects)
                result = MPApplyFix( result, ^MPFixableResult {
                    return [object findAndFixInconsistenciesInContext:context];
                } );
        }

    if (result == MPFixableResultNoProblems)
        inf( @"Sanity check found no problems in store." );

    else {
        [context saveToStore];
        [[NSNotificationCenter defaultCenter] postNotificationName:MPFoundInconsistenciesNotification object:nil userInfo:@{
                MPInconsistenciesFixResultUserKey: @(result)
        }];
    }

    return result;
}

- (void)migrateStore {

    MPStoreMigrationLevel migrationLevel = (signed)[[NSUserDefaults standardUserDefaults] integerForKey:MPMigrationLevelLocalStoreKey];
    if (migrationLevel >= MPStoreMigrationLevelCurrent)
        // Local store up-to-date.
        return;

    inf( @"Local store migration level: %d (current %d)", (signed)migrationLevel, (signed)MPStoreMigrationLevelCurrent );
    if (migrationLevel <= MPStoreMigrationLevelV1 && ![self migrateV1LocalStore]) {
        inf( @"Failed to migrate old V1 to new local store." );
        return;
    }
    if (migrationLevel <= MPStoreMigrationLevelV2 && ![self migrateV2LocalStore]) {
        inf( @"Failed to migrate old V2 to new local store." );
        return;
    }

    [[NSUserDefaults standardUserDefaults] setInteger:MPStoreMigrationLevelCurrent forKey:MPMigrationLevelLocalStoreKey];
    inf( @"Successfully migrated old to new local store." );
    if (![[NSUserDefaults standardUserDefaults] synchronize])
        wrn( @"Couldn't synchronize after store migration." );
}

- (BOOL)migrateV1LocalStore {

    NSURL *applicationFilesDirectory = [[[NSFileManager defaultManager]
            URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
    NSURL *oldLocalStoreURL = [[applicationFilesDirectory
            URLByAppendingPathComponent:@"MasterPassword" isDirectory:NO] URLByAppendingPathExtension:@"sqlite"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:oldLocalStoreURL.path isDirectory:NULL]) {
        inf( @"No V1 local store to migrate." );
        return YES;
    }

    inf( @"Migrating V1 local store" );
    NSURL *newLocalStoreURL = [self localStoreURL];
    if (![[NSFileManager defaultManager] fileExistsAtPath:newLocalStoreURL.path isDirectory:NULL]) {
        inf( @"New local store already exists." );
        return YES;
    }

    NSError *error = nil;
    if (![NSPersistentStore migrateStore:oldLocalStoreURL withOptions:@{ STORE_OPTIONS }
                                 toStore:newLocalStoreURL withOptions:@{ STORE_OPTIONS }
                                   model:nil error:&error]) {
        err( @"Couldn't migrate the old store to the new location: %@", [error fullDescription] );
        return NO;
    }

    return YES;
}

- (BOOL)migrateV2LocalStore {

    NSURL *applicationSupportURL = [[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                                           inDomains:NSUserDomainMask] lastObject];
    NSURL *oldLocalStoreURL;
    // On iOS, each app is in a sandbox so we don't need to app-scope this directory.
#if TARGET_OS_IPHONE
    oldLocalStoreURL = [[applicationSupportURL
            URLByAppendingPathComponent:@"UbiquityStore" isDirectory:NO]
            URLByAppendingPathExtension:@"sqlite"];
#else
    // The directory is shared between all apps on the system so we need to scope it for the running app.
    oldLocalStoreURL = [[[applicationSupportURL
            URLByAppendingPathComponent:[NSRunningApplication currentApplication].bundleIdentifier isDirectory:YES]
            URLByAppendingPathComponent:@"UbiquityStore" isDirectory:NO]
            URLByAppendingPathExtension:@"sqlite"];
#endif

    if (![[NSFileManager defaultManager] fileExistsAtPath:oldLocalStoreURL.path isDirectory:NULL]) {
        inf( @"No V2 local store to migrate." );
        return YES;
    }

    inf( @"Migrating V2 local store" );
    NSURL *newLocalStoreURL = [self localStoreURL];
    if ([[NSFileManager defaultManager] fileExistsAtPath:newLocalStoreURL.path isDirectory:NULL]) {
        inf( @"New local store already exists." );
        return YES;
    }

    NSError *error = nil;
    if (![NSPersistentStore migrateStore:oldLocalStoreURL withOptions:@{
            NSMigratePersistentStoresAutomaticallyOption: @YES,
            NSInferMappingModelAutomaticallyOption      : @YES,
            STORE_OPTIONS
    }                            toStore:newLocalStoreURL withOptions:@{
            NSMigratePersistentStoresAutomaticallyOption: @YES,
            NSInferMappingModelAutomaticallyOption      : @YES,
            STORE_OPTIONS
    }                              model:nil error:&error]) {
        err( @"Couldn't migrate the old store to the new location: %@", [error fullDescription] );
        return NO;
    }

    return YES;
}

#pragma mark - Utilities

- (void)addSiteNamed:(NSString *)siteName completion:(void ( ^ )(MPSiteEntity *site, NSManagedObjectContext *context))completion {

    if (![siteName length]) {
        completion( nil, nil );
        return;
    }

    [MPAppDelegate_Shared managedObjectContextPerformBlock:^(NSManagedObjectContext *context) {
        MPUserEntity *activeUser = [self activeUserInContext:context];
        NSAssert( activeUser, @"Missing user." );
        if (!activeUser) {
            completion( nil, nil );
            return;
        }

        MPSiteType type = activeUser.defaultType;
        id<MPAlgorithm> algorithm = MPAlgorithmDefault;
        Class entityType = [algorithm classOfType:type];

        MPSiteEntity *site = (MPSiteEntity *)[entityType insertNewObjectInContext:context];
        site.name = siteName;
        site.user = activeUser;
        site.type = type;
        site.lastUsed = [NSDate date];
        site.algorithm = algorithm;

        NSError *error = nil;
        if (site.objectID.isTemporaryID && ![context obtainPermanentIDsForObjects:@[ site ] error:&error])
            err( @"Failed to obtain a permanent object ID after creating new site: %@", [error fullDescription] );

        [context saveToStore];

        completion( site, context );
    }];
}

- (MPSiteEntity *)changeSite:(MPSiteEntity *)site saveInContext:(NSManagedObjectContext *)context toType:(MPSiteType)type {

    if (site.type == type)
        return site;

    if ([site.algorithm classOfType:type] == site.typeClass) {
        site.type = type;
        [context saveToStore];
    }

    else {
        // Type requires a different class of site.  Recreate the site.
        Class entityType = [site.algorithm classOfType:type];
        MPSiteEntity *newSite = (MPSiteEntity *)[entityType insertNewObjectInContext:context];
        newSite.type = type;
        newSite.name = site.name;
        newSite.user = site.user;
        newSite.uses = site.uses;
        newSite.lastUsed = site.lastUsed;
        newSite.algorithm = site.algorithm;
        newSite.loginName = site.loginName;

        NSError *error = nil;
        if (![context obtainPermanentIDsForObjects:@[ newSite ] error:&error])
            err( @"Failed to obtain a permanent object ID after changing object type: %@", [error fullDescription] );

        [context deleteObject:site];
        [context saveToStore];

        [[NSNotificationCenter defaultCenter] postNotificationName:MPSiteUpdatedNotification object:site.objectID];
        site = newSite;
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:MPSiteUpdatedNotification object:site.objectID];
    return site;
}

- (MPImportResult)importSites:(NSString *)importedSitesString
            askImportPassword:(NSString *( ^ )(NSString *userName))importPassword
              askUserPassword:(NSString *( ^ )(NSString *userName, NSUInteger importCount, NSUInteger deleteCount))userPassword {

    NSAssert( ![[NSThread currentThread] isMainThread], @"This method should not be invoked from the main thread." );

    __block MPImportResult result = MPImportResultCancelled;
    do {
        if ([MPAppDelegate_Shared managedObjectContextPerformBlockAndWait:^(NSManagedObjectContext *context) {
            result = [self importSites:importedSitesString askImportPassword:importPassword askUserPassword:userPassword
                         saveInContext:context];
        }])
            break;
        usleep( (useconds_t)(USEC_PER_SEC * 0.2) );
    } while (YES);

    return result;
}

- (MPImportResult)importSites:(NSString *)importedSitesString
            askImportPassword:(NSString *( ^ )(NSString *userName))askImportPassword
              askUserPassword:(NSString *( ^ )(NSString *userName, NSUInteger importCount, NSUInteger deleteCount))askUserPassword
                saveInContext:(NSManagedObjectContext *)context {

    // Compile patterns.
    static NSRegularExpression *headerPattern;
    static NSArray *sitePatterns;
    NSError *error = nil;
    if (!headerPattern) {
        headerPattern = [[NSRegularExpression alloc]
                initWithPattern:@"^#[[:space:]]*([^:]+): (.*)"
                        options:(NSRegularExpressionOptions)0 error:&error];
        if (error) {
            err( @"Error loading the header pattern: %@", [error fullDescription] );
            return MPImportResultInternalError;
        }
    }
    if (!sitePatterns) {
        sitePatterns = @[
                [[NSRegularExpression alloc] // Format 0
                        initWithPattern:@"^([^ ]+) +([[:digit:]]+) +([[:digit:]]+)(:[[:digit:]]+)? +([^\t]+)\t(.*)"
                                options:(NSRegularExpressionOptions)0 error:&error],
                [[NSRegularExpression alloc] // Format 1
                        initWithPattern:@"^([^ ]+) +([[:digit:]]+) +([[:digit:]]+)(:[[:digit:]]+)?(:[[:digit:]]+)? +([^\t]*)\t *([^\t]+)\t(.*)"
                                options:(NSRegularExpressionOptions)0 error:&error]
        ];
        if (error) {
            err( @"Error loading the site patterns: %@", [error fullDescription] );
            return MPImportResultInternalError;
        }
    }

    // Parse import data.
    inf( @"Importing sites." );
    __block MPUserEntity *user = nil;
    id<MPAlgorithm> importAlgorithm = nil;
    NSUInteger importFormat = 0;
    NSUInteger importAvatar = NSNotFound;
    NSString *importBundleVersion = nil, *importUserName = nil;
    NSData *importKeyID = nil;
    BOOL headerStarted = NO, headerEnded = NO, clearText = NO;
    NSArray *importedSiteLines = [importedSitesString componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableSet *sitesToDelete = [NSMutableSet set];
    NSMutableArray *importedSiteSites = [NSMutableArray arrayWithCapacity:[importedSiteLines count]];
    NSFetchRequest *siteFetchRequest = [NSFetchRequest fetchRequestWithEntityName:NSStringFromClass( [MPSiteEntity class] )];
    for (NSString *importedSiteLine in importedSiteLines) {
        if ([importedSiteLine hasPrefix:@"#"]) {
            // Comment or header
            if (!headerStarted) {
                if ([importedSiteLine isEqualToString:@"##"])
                    headerStarted = YES;
                continue;
            }
            if (headerEnded)
                continue;
            if ([importedSiteLine isEqualToString:@"##"]) {
                headerEnded = YES;
                continue;
            }

            // Header
            if ([headerPattern numberOfMatchesInString:importedSiteLine options:(NSMatchingOptions)0
                                                 range:NSMakeRange( 0, [importedSiteLine length] )] != 1) {
                err( @"Invalid header format in line: %@", importedSiteLine );
                return MPImportResultMalformedInput;
            }
            NSTextCheckingResult *headerSites = [[headerPattern matchesInString:importedSiteLine options:(NSMatchingOptions)0
                                                                          range:NSMakeRange( 0, [importedSiteLine length] )] lastObject];
            NSString *headerName = [importedSiteLine substringWithRange:[headerSites rangeAtIndex:1]];
            NSString *headerValue = [importedSiteLine substringWithRange:[headerSites rangeAtIndex:2]];
            if ([headerName isEqualToString:@"User Name"]) {
                importUserName = headerValue;

                NSFetchRequest *userFetchRequest = [NSFetchRequest fetchRequestWithEntityName:NSStringFromClass( [MPUserEntity class] )];
                userFetchRequest.predicate = [NSPredicate predicateWithFormat:@"name == %@", importUserName];
                NSArray *users = [context executeFetchRequest:userFetchRequest error:&error];
                if (!users) {
                    err( @"While looking for user: %@, error: %@", importUserName, [error fullDescription] );
                    return MPImportResultInternalError;
                }
                if ([users count] > 1) {
                    err( @"While looking for user: %@, found more than one: %lu", importUserName, (unsigned long)[users count] );
                    return MPImportResultInternalError;
                }

                user = [users lastObject];
                dbg( @"Existing user? %@", [user debugDescription] );
            }
            if ([headerName isEqualToString:@"Key ID"])
                importKeyID = [headerValue decodeHex];
            if ([headerName isEqualToString:@"Version"]) {
                importBundleVersion = headerValue;
                importAlgorithm = MPAlgorithmDefaultForBundleVersion( importBundleVersion );
            }
            if ([headerName isEqualToString:@"Format"]) {
                importFormat = (NSUInteger)[headerValue integerValue];
                if (importFormat >= [sitePatterns count]) {
                    err( @"Unsupported import format: %lu", (unsigned long)importFormat );
                    return MPImportResultInternalError;
                }
            }
            if ([headerName isEqualToString:@"Avatar"])
                importAvatar = (NSUInteger)[headerValue integerValue];
            if ([headerName isEqualToString:@"Passwords"]) {
                if ([headerValue isEqualToString:@"VISIBLE"])
                    clearText = YES;
            }

            continue;
        }
        if (!headerEnded)
            continue;
        if (![importUserName length])
            return MPImportResultMalformedInput;
        if (![importedSiteLine length])
            continue;

        // Site
        NSRegularExpression *sitePattern = sitePatterns[importFormat];
        if ([sitePattern numberOfMatchesInString:importedSiteLine options:(NSMatchingOptions)0
                                           range:NSMakeRange( 0, [importedSiteLine length] )] != 1) {
            err( @"Invalid site format in line: %@", importedSiteLine );
            return MPImportResultMalformedInput;
        }
        NSTextCheckingResult *siteElements = [[sitePattern matchesInString:importedSiteLine options:(NSMatchingOptions)0
                                                                     range:NSMakeRange( 0, [importedSiteLine length] )] lastObject];
        NSString *lastUsed, *uses, *type, *version, *counter, *siteName, *loginName, *exportContent;
        switch (importFormat) {
            case 0:
                lastUsed = [importedSiteLine substringWithRange:[siteElements rangeAtIndex:1]];
                uses = [importedSiteLine substringWithRange:[siteElements rangeAtIndex:2]];
                type = [importedSiteLine substringWithRange:[siteElements rangeAtIndex:3]];
                version = [importedSiteLine substringWithRange:[siteElements rangeAtIndex:4]];
                if ([version length])
                    version = [version substringFromIndex:1]; // Strip the leading colon.
                counter = @"";
                loginName = @"";
                siteName = [importedSiteLine substringWithRange:[siteElements rangeAtIndex:5]];
                exportContent = [importedSiteLine substringWithRange:[siteElements rangeAtIndex:6]];
                break;
            case 1:
                lastUsed = [importedSiteLine substringWithRange:[siteElements rangeAtIndex:1]];
                uses = [importedSiteLine substringWithRange:[siteElements rangeAtIndex:2]];
                type = [importedSiteLine substringWithRange:[siteElements rangeAtIndex:3]];
                version = [importedSiteLine substringWithRange:[siteElements rangeAtIndex:4]];
                if ([version length])
                    version = [version substringFromIndex:1]; // Strip the leading colon.
                counter = [importedSiteLine substringWithRange:[siteElements rangeAtIndex:5]];
                if ([counter length])
                    counter = [counter substringFromIndex:1]; // Strip the leading colon.
                loginName = [importedSiteLine substringWithRange:[siteElements rangeAtIndex:6]];
                siteName = [importedSiteLine substringWithRange:[siteElements rangeAtIndex:7]];
                exportContent = [importedSiteLine substringWithRange:[siteElements rangeAtIndex:8]];
                break;
            default:
                err( @"Unexpected import format: %lu", (unsigned long)importFormat );
                return MPImportResultInternalError;
        }

        // Find existing site.
        if (user) {
            siteFetchRequest.predicate = [NSPredicate predicateWithFormat:@"name == %@ AND user == %@", siteName, user];
            NSArray *existingSites = [context executeFetchRequest:siteFetchRequest error:&error];
            if (!existingSites) {
                err( @"Lookup of existing sites failed for site: %@, user: %@, error: %@", siteName, user.userID, [error fullDescription] );
                return MPImportResultInternalError;
            }
            if ([existingSites count]) {
                dbg( @"Existing sites: %@", existingSites );
                [sitesToDelete addObjectsFromArray:existingSites];
            }
        }
        [importedSiteSites addObject:@[ lastUsed, uses, type, version, counter, loginName, siteName, exportContent ]];
        dbg( @"Will import site: lastUsed=%@, uses=%@, type=%@, version=%@, counter=%@, loginName=%@, siteName=%@, exportContent=%@",
                lastUsed, uses, type, version, counter, loginName, siteName, exportContent );
    }

    // Ask for confirmation to import these sites and the master password of the user.
    inf( @"Importing %lu sites, deleting %lu sites, for user: %@", (unsigned long)[importedSiteSites count],
            (unsigned long)[sitesToDelete count], [MPUserEntity idFor:importUserName] );
    NSString *userMasterPassword = askUserPassword( user? user.name: importUserName, [importedSiteSites count],
            [sitesToDelete count] );
    if (!userMasterPassword) {
        inf( @"Import cancelled." );
        return MPImportResultCancelled;
    }
    MPKey *userKey = [[MPKey alloc] initForFullName:user? user.name: importUserName withMasterPassword:userMasterPassword];
    if (user && ![[userKey keyIDForAlgorithm:user.algorithm] isEqualToData:user.keyID])
        return MPImportResultInvalidPassword;
    __block MPKey *importKey = userKey;
    if (importKeyID && ![[importKey keyIDForAlgorithm:importAlgorithm] isEqualToData:importKeyID])
        importKey = [[MPKey alloc] initForFullName:importUserName withMasterPassword:askImportPassword( importUserName )];
    if (importKeyID && ![[importKey keyIDForAlgorithm:importAlgorithm] isEqualToData:importKeyID])
        return MPImportResultInvalidPassword;

    // Delete existing sites.
    if (sitesToDelete.count)
        [sitesToDelete enumerateObjectsUsingBlock:^(id obj, BOOL *stop) {
            inf( @"Deleting site: %@, it will be replaced by an imported site.", [obj name] );
            [context deleteObject:obj];
        }];

    // Make sure there is a user.
    if (user) {
        if (importAvatar != NSNotFound)
            user.avatar = importAvatar;
        dbg( @"Updating User: %@", [user debugDescription] );
    }
    else {
        user = [MPUserEntity insertNewObjectInContext:context];
        user.name = importUserName;
        user.algorithm = MPAlgorithmDefault;
        user.keyID = [userKey keyIDForAlgorithm:user.algorithm];
        if (importAvatar != NSNotFound)
            user.avatar = importAvatar;
        dbg( @"Created User: %@", [user debugDescription] );
    }

    // Import new sites.
    for (NSArray *siteElements in importedSiteSites) {
        NSDate *lastUsed = [[NSDateFormatter rfc3339DateFormatter] dateFromString:siteElements[0]];
        NSUInteger uses = (unsigned)[siteElements[1] integerValue];
        MPSiteType type = (MPSiteType)[siteElements[2] integerValue];
        MPAlgorithmVersion version = (MPAlgorithmVersion)[siteElements[3] integerValue];
        NSUInteger counter = [siteElements[4] length]? (unsigned)[siteElements[4] integerValue]: NSNotFound;
        NSString *loginName = [siteElements[5] length]? siteElements[5]: nil;
        NSString *siteName = siteElements[6];
        NSString *exportContent = siteElements[7];

        // Create new site.
        id<MPAlgorithm> algorithm = MPAlgorithmForVersion( version );
        Class entityType = [algorithm classOfType:type];
        if (!entityType) {
            err( @"Invalid site type in import file: %@ has type %lu", siteName, (long)type );
            return MPImportResultInternalError;
        }
        MPSiteEntity *site = (MPSiteEntity *)[entityType insertNewObjectInContext:context];
        site.name = siteName;
        site.loginName = loginName;
        site.user = user;
        site.type = type;
        site.uses = uses;
        site.lastUsed = lastUsed;
        site.algorithm = algorithm;
        if ([exportContent length]) {
            if (clearText)
                [site.algorithm importClearTextPassword:exportContent intoSite:site usingKey:userKey];
            else
                [site.algorithm importProtectedPassword:exportContent protectedByKey:importKey intoSite:site usingKey:userKey];
        }
        if ([site isKindOfClass:[MPGeneratedSiteEntity class]] && counter != NSNotFound)
            ((MPGeneratedSiteEntity *)site).counter = counter;

        dbg( @"Created Site: %@", [site debugDescription] );
    }

    if (![context saveToStore])
        return MPImportResultInternalError;

    inf( @"Import completed successfully." );

    [[NSNotificationCenter defaultCenter] postNotificationName:MPSitesImportedNotification object:nil userInfo:@{
            MPSitesImportedNotificationUserKey: user
    }];

    return MPImportResultSuccess;
}

- (NSString *)exportSitesRevealPasswords:(BOOL)revealPasswords {

    MPUserEntity *activeUser = [self activeUserForMainThread];
    inf( @"Exporting sites, %@, for user: %@", revealPasswords? @"revealing passwords": @"omitting passwords", activeUser.userID );

    // Header.
    NSMutableString *export = [NSMutableString new];
    [export appendFormat:@"# Master Password site export\n"];
    if (revealPasswords)
        [export appendFormat:@"#     Export of site names and passwords in clear-text.\n"];
    else
        [export appendFormat:@"#     Export of site names and stored passwords (unless device-private) encrypted with the master key.\n"];
    [export appendFormat:@"# \n"];
    [export appendFormat:@"##\n"];
    [export appendFormat:@"# User Name: %@\n", activeUser.name];
    [export appendFormat:@"# Avatar: %lu\n", (unsigned long)activeUser.avatar];
    [export appendFormat:@"# Key ID: %@\n", [activeUser.keyID encodeHex]];
    [export appendFormat:@"# Date: %@\n", [[NSDateFormatter rfc3339DateFormatter] stringFromDate:[NSDate date]]];
    [export appendFormat:@"# Version: %@\n", [PearlInfoPlist get].CFBundleVersion];
    [export appendFormat:@"# Format: 1\n"];
    if (revealPasswords)
        [export appendFormat:@"# Passwords: VISIBLE\n"];
    else
        [export appendFormat:@"# Passwords: PROTECTED\n"];
    [export appendFormat:@"##\n"];
    [export appendFormat:@"#\n"];
    [export appendFormat:@"#               Last     Times  Password                      Login\t                     Site\tSite\n"];
    [export appendFormat:@"#               used      used      type                       name\t                     name\tpassword\n"];

    // Sites.
    for (MPSiteEntity *site in activeUser.sites) {
        NSDate *lastUsed = site.lastUsed;
        NSUInteger uses = site.uses;
        MPSiteType type = site.type;
        id<MPAlgorithm> algorithm = site.algorithm;
        NSUInteger counter = 0;
        NSString *loginName = site.loginName;
        NSString *siteName = site.name;
        NSString *content = nil;

        // Generated-specific
        if ([site isKindOfClass:[MPGeneratedSiteEntity class]])
            counter = ((MPGeneratedSiteEntity *)site).counter;


        // Determine the content to export.
        if (!(type & MPSiteFeatureDevicePrivate)) {
            if (revealPasswords)
                content = [site.algorithm resolvePasswordForSite:site usingKey:self.key];
            else if (type & MPSiteFeatureExportContent)
                content = [site.algorithm exportPasswordForSite:site usingKey:self.key];
        }

        NSString *lastUsedExport = [[NSDateFormatter rfc3339DateFormatter] stringFromDate:lastUsed];
        long usesExport = (long)uses;
        NSString *typeExport = strf( @"%lu:%lu:%lu", (long)type, (long)[algorithm version], (long)counter );
        NSString *loginNameExport = loginName?: @"";
        NSString *contentExport = content?: @"";
        [export appendFormat:@"%@  %8ld  %8S  %25S\t%25S\t%@\n",
                             lastUsedExport, usesExport,
                             (const unsigned short *)[typeExport cStringUsingEncoding:NSUTF16StringEncoding],
                             (const unsigned short *)[loginNameExport cStringUsingEncoding:NSUTF16StringEncoding],
                             (const unsigned short *)[siteName cStringUsingEncoding:NSUTF16StringEncoding],
                             contentExport];
    }

    return export;
}

@end
