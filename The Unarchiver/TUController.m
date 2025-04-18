#import "TUController.h"
#import "TUArchiveController.h"
#import "TUTaskListView.h"
#import "TUEncodingPopUp.h"
#import "XADMaster/XADPlatform.h"
#import "TUDockTileView.h"

#ifndef IsLegacyVersion
#import "CSURLCache.h"
#endif

#import <unistd.h>
#import <sys/stat.h>
#import <Carbon/Carbon.h>


#define CurrentFolderDestination 1
#define DesktopDestination 2
#define SelectedDestination 3
#define UnintializedDestination 4

static BOOL IsPathWritable(NSString *path);



@implementation TUController

-(id)init
{
	if((self=[super init]))
	{
		setuptasks=[TUTaskQueue new];
		extracttasks=[TUTaskQueue new];
		archivecontrollers=[NSMutableArray new];
		selecteddestination=nil;

		if([NSApp respondsToSelector:@selector(dockTile)]) docktile=[[TUDockTileView alloc] init];
		else docktile=nil;

		opened=NO;

		[setuptasks setFinishAction:@selector(setupQueueEmpty:) target:self];
		[extracttasks setFinishAction:@selector(extractQueueEmpty:) target:self];
	}
	return self;
}

-(void)dealloc
{
	[setuptasks release];
	[extracttasks release];
	[archivecontrollers release];
	[selecteddestination release];

	if(docktile)
	{
		[[NSApp dockTile] setContentView:nil];
		[docktile release];
	}

	[super dealloc];
}

-(void)awakeFromNib
{
	[self updateDestinationPopup];

	[mainlist setResizeAction:@selector(listResized:) target:self];

	if(floor(NSAppKitVersionNumber)<=NSAppKitVersionNumber10_3)
	[prefstabs removeTabViewItem:formattab];

	[encodingpopup buildEncodingListWithAutoDetect];
	NSStringEncoding encoding=[[NSUserDefaults standardUserDefaults] integerForKey:@"filenameEncoding"];
//	if(encoding) [encodingpopup selectItemWithTag:encoding];
	if(encoding) [encodingpopup selectItemAtIndex:[encodingpopup indexOfItemWithTag:encoding]];
	else [encodingpopup selectItemAtIndex:[encodingpopup numberOfItems]-1];

	[self changeCreateFolder:nil];

	if(docktile) [[NSApp dockTile] setContentView:docktile];

	[self cleanupOrphanedTempDirectories];
}

-(void)cleanupOrphanedTempDirectories
{
	NSUserDefaults *defs=[NSUserDefaults standardUserDefaults];
	NSFileManager *fm=[NSFileManager defaultManager];

	NSArray *tmpdirs=[defs arrayForKey:@"orphanedTempDirectories"];
	NSEnumerator *enumerator=[tmpdirs objectEnumerator];
	NSString *tmpdir;
	while((tmpdir=[enumerator nextObject]))
	{
		#ifdef IsLegacyVersion
		[fm removeFileAtPath:tmpdir handler:nil];
		#else
		NSURL *url=[[CSURLCache defaultCache] securityScopedURLAllowingAccessToPath:tmpdir];
		[url startAccessingSecurityScopedResource];
		[fm removeItemAtPath:tmpdir error:nil];
		[url stopAccessingSecurityScopedResource];
		#endif
	}

	[defs setObject:[NSArray array] forKey:@"orphanedTempDirectories"];
	[defs synchronize];
}




-(NSWindow *)window { return mainwindow; }

-(BOOL)hasRunningExtractions
{
	return [archivecontrollers count]!=0;
}



-(void)applicationDidFinishLaunching:(NSNotification *)notification
{
	[NSApp setServicesProvider:self];
	[self performSelector:@selector(delayedAfterLaunch) withObject:nil afterDelay:0.3];

	#ifndef IsLegacyVersion
	if([[NSUserDefaults standardUserDefaults] integerForKey:@"extractionDestination"]==UnintializedDestination)
	{
		NSArray *array=[[NSBundle mainBundle] preferredLocalizations];
		if(array && [array count] && [[array objectAtIndex:0] isEqual:@"en"])
		{
			NSAlert *panel=[NSAlert alertWithMessageText:
			NSLocalizedString(@"Where should The OpenUnarchiver extract archives?",@"Title for nagging alert on first startup")
			defaultButton:NSLocalizedString(@"Extract to the same folder",@"Button to extract to the same folder in nagging alert on first startup")
			alternateButton:NSLocalizedString(@"Ask every time",@"Button to ask every time in nagging alert on first startup")
			otherButton:nil
			informativeTextWithFormat:NSLocalizedString(
			@"Would you like The OpenUnarchiver to extract archives to the same folder as the "
			@"archive file, or would you prefer to be asked for a destination folder for "
			@"every individual archive?",
			@"Content of nagging alert on first startup")];

			NSInteger res=[panel runModal];
			if(res==NSOKButton) [[NSUserDefaults standardUserDefaults]
			setInteger:CurrentFolderDestination forKey:@"extractionDestination"];
			else [[NSUserDefaults standardUserDefaults]
			setInteger:SelectedDestination forKey:@"extractionDestination"];
		}
		else
		{
			[[NSUserDefaults standardUserDefaults]
			setInteger:CurrentFolderDestination forKey:@"extractionDestination"];
		}
	}
	#endif
}

-(void)delayedAfterLaunch
{
	// This is an ugly kludge because we can't tell if we're launched
	// because of a service call.
	if(!opened)
	{
		[prefswindow makeKeyAndOrderFront:nil];
	}
}

-(BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app 
{
	return YES;
}

-(void)applicationWillTerminate:(NSNotification *)notification
{
	// Make double sure overlays and badges on the app icon are gone.
	// Not sure if this is needed, but there have been problems with them getting
	// stuck in LaunchPad.
	[[NSApp dockTile] setContentView:nil];
	[[NSApp dockTile] setBadgeLabel:nil];
}

-(BOOL)application:(NSApplication *)app openFile:(NSString *)filename
{
	opened=YES;

	#ifndef IsLegacyVersion
	// Get rid of sandbox junk.
	filename=[filename stringByResolvingSymlinksInPath];
	#endif

	int desttype;
	if(GetCurrentKeyModifiers()&(optionKey|shiftKey)) desttype=SelectedDestination;
	else desttype=(int)[[NSUserDefaults standardUserDefaults] integerForKey:@"extractionDestination"];

	[self newArchiveForFile:filename destination:desttype];
	return YES;
}



-(void)newArchivesForFiles:(NSArray *)filenames destination:(int)desttype
{
	NSEnumerator *enumerator=[filenames objectEnumerator];
	NSString *filename;
	while((filename=[enumerator nextObject])) [self newArchiveForFile:filename destination:desttype];
}

-(void)newArchivesForURLs:(NSArray *)urls destination:(int)desttype
{
	NSEnumerator *enumerator=[urls objectEnumerator];
	NSURL *url;
	while((url=[enumerator nextObject])) [self newArchiveForFile:[url path] destination:desttype];
}

-(void)newArchiveForFile:(NSString *)filename destination:(int)desttype
{
	// Check if this file is already included in any of the currently queued archives.
	if([self archiveControllerForFilename:filename]) return;

	TUArchiveController *archive=[[[TUArchiveController alloc] initWithFilename:filename] autorelease];
	[archive setDestination:[self destinationForFilename:filename type:desttype]];
	[self addArchiveController:archive];
}

-(NSString *)destinationForFilename:(NSString *)filename type:(int)desttype
{
	switch(desttype)
	{
		default:
		case CurrentFolderDestination:
			return [filename stringByDeletingLastPathComponent];

		case DesktopDestination:
			return [[NSUserDefaults standardUserDefaults] stringForKey:@"extractionDestinationPath"];

		case SelectedDestination:
			return nil;
	}
}

-(void)addArchiveController:(TUArchiveController *)archive
{
	// Create status view and archive controller.
	TUArchiveTaskView *taskview=[[TUArchiveTaskView new] autorelease];

	[taskview setCancelAction:@selector(archiveTaskViewCancelledBeforeSetup:) target:self];
	[taskview setArchiveController:archive];
	[taskview setupWaitView];
	[mainlist addTaskView:taskview];

	[archive setTaskView:taskview];
	[archive setDockTileView:docktile];

	[archivecontrollers addObject:archive];
	[docktile setCount:(int)[archivecontrollers count]];

	[NSApp activateIgnoringOtherApps:YES];
	[mainwindow makeKeyAndOrderFront:nil];

	[[setuptasks taskWithTarget:self] setupExtractionForArchiveController:archive];
}

-(TUArchiveController *)archiveControllerForFilename:(NSString *)filename
{
	NSEnumerator *enumerator=[archivecontrollers objectEnumerator];
	TUArchiveController *archive;
	while((archive=[enumerator nextObject]))
	{
		if([archive isCancelled]) continue;
		NSArray *filenames=[archive allFilenames];
		if([filenames containsObject:filename]) return archive;
	}
	return nil;
}




-(void)archiveTaskViewCancelledBeforeSetup:(TUArchiveTaskView *)taskview
{
	[mainlist removeTaskView:taskview];
	[[taskview archiveController] setIsCancelled:YES];
}




-(void)setupExtractionForArchiveController:(TUArchiveController *)archive
{
	if([archive isCancelled])
	{
 		[archivecontrollers removeObjectIdenticalTo:archive];
		[docktile setCount:(int)[archivecontrollers count]];
		[setuptasks finishCurrentTask];
		return;
	}

	[[archive taskView] setCancelAction:NULL target:nil];

	if(![archive destination]) [archive setDestination:selecteddestination];

	[self checkDestinationForArchiveController:archive];
}

-(void)checkDestinationForArchiveController:(TUArchiveController *)archive
{
	[self checkDestinationForArchiveController:archive secondAttempt:NO];
}

-(void)checkDestinationForArchiveControllerAgain:(TUArchiveController *)archive
{
	[self checkDestinationForArchiveController:archive secondAttempt:YES];
}

-(void)checkDestinationForArchiveController:(TUArchiveController *)archive secondAttempt:(BOOL)secondattempt
{
	NSString *destination=[archive destination];

	if(!destination)
	{
		// No destination supplied. This means we need to ask the user.
		NSOpenPanel *panel=[NSOpenPanel openPanel];
		[panel setCanCreateDirectories:YES];
		[panel setCanChooseDirectories:YES];
		[panel setCanChooseFiles:NO];
		//[panel setTitle:NSLocalizedString(@"Extract Archive",@"Panel title when choosing an unarchiving destination for an archive")];
		[panel setPrompt:NSLocalizedString(@"Extract",@"Panel OK button title when choosing an unarchiving destination for an archive")];

		NSString *rememberedpath=[[NSUserDefaults standardUserDefaults] stringForKey:@"lastDestination"];

		#ifdef IsLegacyVersion
		if(rememberedpath) [panel setDirectory:rememberedpath];
		[panel beginSheetForDirectory:nil file:nil modalForWindow:mainwindow
		modalDelegate:self didEndSelector:@selector(archiveDestinationPanelDidEnd:returnCode:contextInfo:)
		contextInfo:archive];
		#else
		if(rememberedpath) [panel setDirectoryURL:[NSURL fileURLWithPath:rememberedpath]];
		[panel beginSheetModalForWindow:mainwindow completionHandler:^(NSInteger result) {
			[self archiveDestinationPanelDidEnd:panel returnCode:(int)result contextInfo:archive];
		}];
		#endif

		return;
	}
	else
	{
		#ifndef IsLegacyVersion
		// On the first attempt to access a given path, try to find a cached
		// security-scoped URL for this path, and use it, even if we already have
		// access. (This is to balance the number of starts and stops for the URL.)
		if(!secondattempt)
		{
			NSURL *scopedurl=[[CSURLCache defaultCache] securityScopedURLAllowingAccessToPath:destination];
			[archive useSecurityScopedURL:scopedurl];
		}
		#endif
	}

	if(!IsPathWritable(destination))
	{
		#ifdef IsLegacyVersion

		// Can not write to the given destination. Show an error.
		[[archive taskView] displayNotWritableErrorWithResponseAction:@selector(archiveTaskView:notWritableResponse:) target:self];
		return;

		#else

		// Can not write to the given destination. Open a file
		// panel to get sandbox access to the directory, or show an error
		// if a file panel was already shown.
		if(!IsPathWritable(destination))
		{
			if(secondattempt)
			{
				[[archive taskView] displayNotWritableErrorWithResponseAction:@selector(archiveTaskView:notWritableResponse:) target:self];
			}
			else
			{
				NSOpenPanel *panel=[NSOpenPanel openPanel];

				NSTextField *text=[[[NSTextField alloc] initWithFrame:NSMakeRect(0,0,100,100)] autorelease];

				[text setStringValue:NSLocalizedString(
				@"The OpenUnarchiver does not have permission to write to this folder. "
				@"To allow The OpenUnarchiver to write to this folder, simply click "
				@"\"Extract\". This permission will be remembered for this folder, and "
				@"The OpenUnarchiver will not need to ask for it again.",
				@"Informative text in the file panel shown when trying to gain sandbox access")];
				[text setBezeled:NO];
				[text setDrawsBackground:NO];
				[text setEditable:NO];
				[text setSelectable:NO];
				[text setFont:[NSFont systemFontOfSize:[NSFont systemFontSizeForControlSize:[[text cell] controlSize]]]];

				NSSize size=[[text cell] cellSizeForBounds:NSMakeRect(0,0,460,100000)];
				[text setFrame:NSMakeRect(0,0,size.width,size.height)];

				[panel setAccessoryView:text];

				[panel setCanCreateDirectories:YES];
				[panel setCanChooseDirectories:YES];
				[panel setCanChooseFiles:NO];
				[panel setPrompt:NSLocalizedString(@"Extract",@"Panel OK button title when choosing an unarchiving destination for an archive")];
				[panel setDirectoryURL:[NSURL fileURLWithPath:destination]];

				[panel beginSheetModalForWindow:mainwindow completionHandler:^(NSInteger result) {
					[self archiveDestinationPanelDidEnd:panel returnCode:(int)result contextInfo:archive];
				}];
			}
			return;
		}

		#endif
	}

	// Continue the setup process by trying to initialize the unarchiver,
	// and handle getting access from the sandbox to scan for volume files.
	[self prepareArchiveController:archive];
}

-(void)archiveDestinationPanelDidEnd:(NSOpenPanel *)panel returnCode:(int)res contextInfo:(void  *)info
{
	TUArchiveController *archive=(id)info;

	if(res==NSOKButton)
	{
		[selecteddestination release];

		#ifdef IsLegacyVersion
		selecteddestination=[[panel directory] retain];
		#else
		NSURL *url=[panel URL];
		[[CSURLCache defaultCache] cacheSecurityScopedURL:url];
		selecteddestination=[[url path] retain];
		#endif

		[[NSUserDefaults standardUserDefaults] setObject:selecteddestination forKey:@"lastDestination"];

		[archive setDestination:selecteddestination];
		[self performSelector:@selector(checkDestinationForArchiveControllerAgain:) withObject:archive afterDelay:0];
	}
	else
	{
		[self performSelector:@selector(cancelSetupForArchiveController:) withObject:archive afterDelay:0];
	}
}

-(void)archiveTaskView:(TUArchiveTaskView *)taskview notWritableResponse:(int)response
{
	TUArchiveController *archive=[taskview archiveController];

	switch(response)
	{
		case 0: // Cancel.
			[self cancelSetupForArchiveController:archive];
		break;

		case 1: // To desktop.
		{
			NSString *desktop=[NSSearchPathForDirectoriesInDomains(
			NSDesktopDirectory,NSUserDomainMask,YES) objectAtIndex:0];
			[archive setDestination:desktop];
			[self checkDestinationForArchiveController:archive];
		}
		break;

		case 2: // Elsewhere.
			[archive setDestination:nil];
			[self checkDestinationForArchiveController:archive];
		break;
	}
}

-(void)prepareArchiveController:(TUArchiveController *)archive
{
	#ifdef IsLegacyVersion

	// With no sandbox, this is easy.
	[archive prepare];
	[self finishSetupForArchiveController:archive];

	#else

	// With the sandbox, on the other hand...

	[archive prepare];

	if(![archive volumeScanningFailed])
	{
		// Miraculously, all went well. Finish.
		[self finishSetupForArchiveController:archive];
	}
	else
	{
		// We were denied access to the directory.
		// First attempt to get access using the URL cache.
		NSString *directory=[[archive filename] stringByDeletingLastPathComponent];

		NSURL *scopedurl=[[CSURLCache defaultCache] securityScopedURLAllowingAccessToPath:directory];
		if(scopedurl)
		{
			[archive useSecurityScopedURL:scopedurl];
			[archive prepare];
			[self finishSetupForArchiveController:archive];
		}
		else
		{
			// No access available in the cache. Nag the user.
			NSOpenPanel *panel=[NSOpenPanel openPanel];

			NSTextField *text=[[[NSTextField alloc] initWithFrame:NSMakeRect(0,0,100,100)] autorelease];

			[text setStringValue:NSLocalizedString(
			@"The OpenUnarchiver needs to search for more parts of this archive, "
			@"but does not have permission to read the folder. "
			@"To allow The OpenUnarchiver to search in "
			@"this folder, simply click \"Search\". This permission will be "
			@"remembered for this folder, and The OpenUnarchiver will not need to ask for it again.",
			@"Informative text in the file panel shown when trying to gain sandbox access for multi-part archives")];
			[text setBezeled:NO];
			[text setDrawsBackground:NO];
			[text setEditable:NO];
			[text setSelectable:NO];
			[text setFont:[NSFont systemFontOfSize:[NSFont systemFontSizeForControlSize:[[text cell] controlSize]]]];

			NSSize size=[[text cell] cellSizeForBounds:NSMakeRect(0,0,460,100000)];
			[text setFrame:NSMakeRect(0,0,size.width,size.height)];

			[panel setAccessoryView:text];

			[panel setCanCreateDirectories:YES];
			[panel setCanChooseDirectories:YES];
			[panel setCanChooseFiles:NO];
			[panel setPrompt:NSLocalizedString(@"Search",@"Panel OK button title when searching for more archive parts")];
			[panel setDirectoryURL:[NSURL fileURLWithPath:directory]];

			[panel beginSheetModalForWindow:mainwindow completionHandler:^(NSInteger result) {
				if(result==NSFileHandlingPanelOKButton)
				{
					NSURL *url=[panel URL];
					[[CSURLCache defaultCache] cacheSecurityScopedURL:url];
					[archive prepare];
					[self performSelector:@selector(finishSetupForArchiveController:) withObject:archive afterDelay:0];
				}
				else
				{
					[self performSelector:@selector(cancelSetupForArchiveController:) withObject:archive afterDelay:0];
				}
			}];
		}
	}

	#endif
}

-(void)finishSetupForArchiveController:(TUArchiveController *)archive
{
	// All done. Go ahead and start an extraction task.
	[[archive taskView] updateWaitView];
	[[archive taskView] setCancelAction:@selector(archiveTaskViewCancelledBeforeExtract:) target:self];

	[[extracttasks taskWithTarget:self] startExtractionForArchiveController:archive];

	[setuptasks finishCurrentTask];
}

-(void)cancelSetupForArchiveController:(TUArchiveController *)archive
{
	[archivecontrollers removeObjectIdenticalTo:archive];
	[docktile setCount:(int)[archivecontrollers count]];
	[mainlist removeTaskView:[archive taskView]];
	[setuptasks finishCurrentTask];
}

-(void)setupQueueEmpty:(TUTaskQueue *)queue
{
	if([extracttasks isEmpty])
	{
		if([mainwindow isMiniaturized]) [mainwindow close];
		else [mainwindow orderOut:nil];
	}

	[selecteddestination release];
	selecteddestination=nil;
}

-(void)archiveTaskViewCancelledBeforeExtract:(TUArchiveTaskView *)taskview
{
	[mainlist removeTaskView:taskview];
	[[taskview archiveController] setIsCancelled:YES];
}




-(void)startExtractionForArchiveController:(TUArchiveController *)archive
{
	if([archive isCancelled])
	{
		[archivecontrollers removeObjectIdenticalTo:archive];
		[docktile setCount:(int)[archivecontrollers count]];
		[extracttasks finishCurrentTask];
		return;
	}

	[[archive taskView] setupProgressViewInPreparingMode];

	[archive runWithFinishAction:@selector(archiveControllerFinished:) target:self];
}

-(void)archiveControllerFinished:(TUArchiveController *)archive
{
	[archivecontrollers removeObjectIdenticalTo:archive];
	[docktile setCount:(int)[archivecontrollers count]];
	[mainlist removeTaskView:[archive taskView]];
	[extracttasks finishCurrentTask];
}

-(void)extractQueueEmpty:(TUTaskQueue *)queue
{
	if([setuptasks isEmpty])
	{
		if([mainwindow isMiniaturized]) [mainwindow close];
		else [mainwindow orderOut:nil];
	}

	[TUArchiveController clearGlobalPassword];
}




-(void)listResized:(id)sender
{
	NSSize size=[mainlist preferredSize];
	if(size.height==0) return;

	NSRect frame=[mainwindow contentRectForFrameRect:[mainwindow frame]];
	NSRect newframe=[mainwindow frameRectForContentRect:
		NSMakeRect(frame.origin.x,frame.origin.y+frame.size.height-size.height,
		size.width,size.height)];

	[mainwindow setMinSize:NSMakeSize(316,newframe.size.height)];
	[mainwindow setMaxSize:NSMakeSize(100000,newframe.size.height)];
	[mainwindow setFrame:newframe display:YES animate:NO];
}



-(void)updateDestinationPopup
{
	NSString *path=[[NSUserDefaults standardUserDefaults] stringForKey:@"extractionDestinationPath"];
	NSImage *icon=[TUController iconForPath:path];

	[icon setSize:NSMakeSize(16,16)];

	[diritem setTitle:[[NSFileManager defaultManager] displayNameAtPath:path]];
	[diritem setImage:icon];
}

-(IBAction)changeDestination:(id)sender
{
	if([destinationpopup selectedTag]==1000)
	{
		NSString *oldpath=[[NSUserDefaults standardUserDefaults] stringForKey:@"extractionDestinationPath"];
		NSOpenPanel *panel=[NSOpenPanel openPanel];

		[panel setCanChooseDirectories:YES];
		[panel setCanCreateDirectories:YES];
		[panel setCanChooseFiles:NO];
		[panel setPrompt:NSLocalizedString(@"Select",@"Panel OK button title when choosing a default unarchiving destination")];

		#ifdef IsLegacyVersion
		[panel beginSheetForDirectory:oldpath file:@"" types:nil
		modalForWindow:prefswindow modalDelegate:self
		didEndSelector:@selector(destinationPanelDidEnd:returnCode:contextInfo:)
		contextInfo:nil];
		#else
		[panel setDirectoryURL:[NSURL fileURLWithPath:oldpath]];
		[panel setAllowedFileTypes:nil];
		[panel beginSheetModalForWindow:prefswindow completionHandler:^(NSInteger result) {
			[self destinationPanelDidEnd:panel returnCode:(int)result contextInfo:nil];
		}];
		#endif
	}
}

-(void)destinationPanelDidEnd:(NSOpenPanel *)panel returnCode:(int)res contextInfo:(void  *)context
{
	if(res==NSOKButton)
	{
		#ifdef IsLegacyVersion
		NSString *directory=[panel directory];
		#else
		NSURL *url=[panel URL];
		[[CSURLCache defaultCache] cacheSecurityScopedURL:url];
		NSString *directory=[url path];
		#endif

		[[NSUserDefaults standardUserDefaults] setObject:directory forKey:@"extractionDestinationPath"];
		[self updateDestinationPopup];
	}

	[destinationpopup selectItem:diritem];
	[[NSUserDefaults standardUserDefaults] setInteger:2 forKey:@"extractionDestination"];
}



-(void)unarchiveToCurrentFolderWithPasteboard:(NSPasteboard *)pboard
userData:(NSString *)data error:(NSString **)error
{
	opened=YES;
	if([[pboard types] containsObject:NSFilenamesPboardType])
	{
		NSArray *filenames=[pboard propertyListForType:NSFilenamesPboardType];
		[self newArchivesForFiles:filenames destination:CurrentFolderDestination];
	}
}

-(void)unarchiveToDesktopWithPasteboard:(NSPasteboard *)pboard
userData:(NSString *)data error:(NSString **)error
{
	opened=YES;
	if([[pboard types] containsObject:NSFilenamesPboardType])
	{
		NSArray *filenames=[pboard propertyListForType:NSFilenamesPboardType];
		[self newArchivesForFiles:filenames destination:DesktopDestination];
	}
}

-(void)unarchiveToWithPasteboard:(NSPasteboard *)pboard
userData:(NSString *)data error:(NSString **)error
{
	opened=YES;
	if([[pboard types] containsObject:NSFilenamesPboardType])
	{
		NSArray *filenames=[pboard propertyListForType:NSFilenamesPboardType];
		[self newArchivesForFiles:filenames destination:SelectedDestination];
	}
}



-(IBAction)unarchiveToCurrentFolder:(id)sender
{
	[self selectAndUnarchiveFilesWithDestination:CurrentFolderDestination];
}

-(IBAction)unarchiveToDesktop:(id)sender
{
	[self selectAndUnarchiveFilesWithDestination:DesktopDestination];
}

-(IBAction)unarchiveTo:(id)sender
{
	[self selectAndUnarchiveFilesWithDestination:SelectedDestination];
}

-(void)selectAndUnarchiveFilesWithDestination:(int)desttype
{
	NSOpenPanel *panel=[NSOpenPanel openPanel];

	[panel setCanChooseFiles:YES];
	[panel setAllowsMultipleSelection:YES];
	[panel setTitle:NSLocalizedString(@"Select files to unarchive",@"Panel title when choosing archives to extract")];
	[panel setPrompt:NSLocalizedString(@"Unarchive",@"Panel OK button title when choosing archives to extract")];

	int res=(int)[panel runModal];

	if(res==NSOKButton)
	{
		#ifdef IsLegacyVersion
		[self newArchivesForFiles:[panel filenames] destination:desttype];
		#else
		[self newArchivesForURLs:[panel URLs] destination:desttype];
		#endif
	}
}



-(IBAction)changeCreateFolder:(id)sender
{
	int createfolder=(int)[[NSUserDefaults standardUserDefaults] integerForKey:@"createFolder"];
	[singlefilecheckbox setEnabled:createfolder==1];
}




-(IBAction)openSupportBoard:(id)sender
{
	[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"http://wakaba.c3.cx/sup/"]];
}

-(IBAction)openBugReport:(id)sender
{
	[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"http://code.google.com/p/theunarchiver/issues/list"]];
}

-(IBAction)openHomePage:(id)sender
{
	[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"http://unarchiver.c3.cx/"]];
}

-(BOOL)application:(NSApplication *)sender delegateHandlesKey:(NSString *)key
{
	if ([key isEqualToString:@"hasRunningExtractions"]) return YES;
	return NO;
}

+(NSImage *)iconForPath:(NSString *)path
{
	NSString *usernameregex=[NSUserName() escapedPattern];

	#define regexForUserPath(path) [NSString stringWithFormat:@"/%@/%@$",usernameregex,path,nil]
	#define folderIconNamed(iconName) [[[NSImage alloc] initWithContentsOfFile:@"/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/" iconName] autorelease]

	NSImage *icon=nil;

	if([path matchedByPattern:[NSString stringWithFormat:@"/%@$",usernameregex,nil]]) icon=folderIconNamed(@"HomeFolderIcon.icns");
	else if([path matchedByPattern:regexForUserPath(@"Desktop")]) icon=folderIconNamed(@"DesktopFolderIcon.icns");
	else if([path matchedByPattern:regexForUserPath(@"Documents")]) icon=folderIconNamed(@"DocumentsFolderIcon.icns");
	else if([path matchedByPattern:regexForUserPath(@"Public")]) icon=folderIconNamed(@"PublicFolderIcon.icns");
	else if([path matchedByPattern:regexForUserPath(@"Pictures")]) icon=folderIconNamed(@"PicturesFolderIcon.icns");
	else if([path matchedByPattern:regexForUserPath(@"Downloads")]) icon=folderIconNamed(@"DownloadsFolder.icns");
	else if([path matchedByPattern:regexForUserPath(@"Movies")]) icon=folderIconNamed(@"MovieFolderIcon.icns");
	else if([path matchedByPattern:regexForUserPath(@"Music")]) icon=folderIconNamed(@"MusicFolderIcon.icns");
	else if([path matchedByPattern:regexForUserPath(@"Sites")]) icon=folderIconNamed(@"SitesFolderIcon.icns");

	if(!icon) icon=[[NSWorkspace sharedWorkspace] iconForFile:path];

	return icon;
}

@end




static BOOL IsPathWritable(NSString *path)
{
	if(access([path fileSystemRepresentation],W_OK)==-1) return NO;

	return YES;
}


/*-(void)lockFileSystem:(NSString *)filename
{
	NSNumber *key=[self _fileSystemNumber:filename];

	[metalock lock];
	if(![filesyslocks objectForKey:key]) [filesyslocks setObject:[[[NSLock alloc] init] autorelease] forKey:key];
	NSLock *lock=[filesyslocks objectForKey:key];
	[metalock unlock];

	[lock lock];
}

-(BOOL)tryFileSystemLock:(NSString *)filename
{
	NSNumber *key=[self _fileSystemNumber:filename];

	[metalock lock];
	if(![filesyslocks objectForKey:key]) [filesyslocks setObject:[[[NSLock alloc] init] autorelease] forKey:key];
	NSLock *lock=[filesyslocks objectForKey:key];
	[metalock unlock];

	return [lock tryLock];
}

-(void)unlockFileSystem:(NSString *)filename
{
	NSNumber *key=[self _fileSystemNumber:filename];

	[metalock lock];
	NSLock *lock=[filesyslocks objectForKey:key];
	[metalock unlock];

	[lock unlock];
}

-(NSNumber *)_fileSystemNumber:(NSString *)filename
{
	struct stat st;
	lstat([filename fileSystemRepresentation],&st);
	return [NSNumber numberWithUnsignedLong:st.st_dev];
}*/
