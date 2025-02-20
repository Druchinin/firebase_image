import 'dart:io';
import 'dart:typed_data';

import 'package:firebase_image/src/firebase_image.dart';
import 'package:firebase_image/src/image_object.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart';

class FirebaseImageCacheManager {
  static const String key = 'firebase_image';

  Database db;
  String dbName = '$key.db';
  String table = 'images';
  String basePath;

  Future open() async {
    db = await openDatabase(
      join(await getDatabasesPath(), dbName),
      onCreate: (Database db, int version) async {
        await db.execute('''
          CREATE TABLE $table (
            uri TEXT PRIMARY KEY,
            remotePath TEXT, 
            localPath TEXT, 
            bucket TEXT, 
            version INTEGER
          )
        ''');
      },
      version: 1,
    );
    basePath = await _createFilePath();
  }

  Future<FirebaseImageObject> insert(FirebaseImageObject model) async {
    await db.insert('images', model.toMap());
    return model;
  }

  Future<FirebaseImageObject> update(FirebaseImageObject model) async {
    await db.update(
      table,
      model.toMap(),
      where: 'uri = ?',
      whereArgs: [model.uri],
    );
    return model;
  }

  Future<FirebaseImageObject> upsert(FirebaseImageObject object) async {
    if (await checkDatabaseForEntry(object)) {
      return await update(object);
    } else {
      return await insert(object);
    }
  }

  Future<bool> checkDatabaseForEntry(FirebaseImageObject object) async {
    List<Map> maps = await db.query(
      table,
      columns: null,
      where: 'uri = ?',
      whereArgs: [object.uri],
    );
    return maps.length > 0;
  }

  Future<FirebaseImageObject> get(String uri, FirebaseImage image) async {
    List<Map> maps = await db.query(
      table,
      columns: null,
      where: 'uri = ?',
      whereArgs: [uri],
    );
    if (maps.length > 0) {
      FirebaseImageObject returnObject =
          new FirebaseImageObject.fromMap(maps.first);
      returnObject.reference = getImageRef(returnObject, image.firebaseApp);
      checkForUpdate(returnObject, image); // Check for update in background
      return returnObject;
    }
    return null;
  }

  StorageReference getImageRef(
      FirebaseImageObject object, FirebaseApp firebaseApp) {
    FirebaseStorage storage =
        FirebaseStorage(app: firebaseApp, storageBucket: object.bucket);
    return storage.ref().child(object.remotePath);
  }

  Future<void> checkForUpdate(
      FirebaseImageObject object, FirebaseImage image) async {
    int remoteVersion =
        (await object.reference.getMetadata()).updatedTimeMillis;
    if (remoteVersion != object.version) {
      // If true, download new image for next load
      await this.upsertRemoteFileToCache(object, image.maxSizeBytes);
    }
  }

  Future<List<FirebaseImageObject>> getAll() async {
    final List<Map<String, dynamic>> maps = await db.query(table);
    return List.generate(maps.length, (i) {
      return FirebaseImageObject.fromMap(maps[i]);
    });
  }

  Future<int> delete(String uri) async {
    return await db.delete(
      table,
      where: 'uri = ?',
      whereArgs: [uri],
    );
  }

  Future<Uint8List> localFileBytes(FirebaseImageObject object) async {
    if (await _fileExists(object)) {
      return new File(object.localPath).readAsBytes();
    }
    return null;
  }

  Future<Uint8List> remoteFileBytes(
      FirebaseImageObject object, int maxSizeBytes) {
    return object.reference.getData(maxSizeBytes);
  }

  Future<Uint8List> upsertRemoteFileToCache(
      FirebaseImageObject object, int maxSizeBytes) async {
    object.version = (await object.reference.getMetadata()).updatedTimeMillis;
    Uint8List bytes = await remoteFileBytes(object, maxSizeBytes);
    await putFile(object, bytes);
    return bytes;
  }

  Future<FirebaseImageObject> putFile(
      FirebaseImageObject object, final bytes) async {
    String path = basePath + "/" + object.remotePath;
    path = path.replaceAll("//", "/");
    //print(join(basePath, object.remotePath)); Join isn't working?
    await new File(path).create(recursive: true);
    var file = await new File(path).writeAsBytes(bytes);
    object.localPath = file.path;
    return await upsert(object);
  }

  Future<bool> _fileExists(FirebaseImageObject object) async {
    if (object?.localPath == null) {
      return false;
    }
    return new File(join(object.localPath)).exists();
  }

  Future<String> _createFilePath() async {
    var directory = await getTemporaryDirectory();
    return join(directory.path, key);
  }

  Future<void> close() async => await db.close();
}
