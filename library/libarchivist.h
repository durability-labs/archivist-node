/**
 * libarchivist.h - C-exported interface for the Archivist shared library
 *
 * This file implements the public C API for libarchivist. It acts as the bridge
 * between C programs and the internal Nim implementation.
 *
 * Unless it is explicitly stated otherwise, all functions are asynchronous and execute
 * their work on a separate thread, returning results via the provided callback. The
 * result code of the function represents the synchronous status of the call itself:
 * returning RET_OK if the job has been dispatched to the thread, and RET_ERR in case
 * of immediate failure.
 *
 * The callback function is invoked with the result of the operation, including
 * any data or error messages. If the call was successful, `callerRet` will be RET_OK,
 * and `msg` will contain the result data. If there was an error, `callerRet` will be RET_ERR,
 * and `msg` will contain the error message.
 *
 * When a function supports progress updates, it may invoke the callback multiple times:
 * first with RET_PROGRESS and progress information, and finally with RET_OK or RET_ERR
 * upon completion. The msg parameter will a chunk of data for upload and download operations.
 *
 * `userData` is a pointer provided by the caller that is passed back to the callback
 * for context.
 */

#ifndef __libarchivist__
#define __libarchivist__

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Return codes for FFI functions
 */
#define RET_OK 0
#define RET_ERR 1
#define RET_MISSING_CALLBACK 2
#define RET_PROGRESS 3

/**
 * Callback function type for asynchronous operations
 * 
 * @param callerRet The return code (RET_OK, RET_ERR, RET_PROGRESS)
 * @param msg The message data (result, error, or progress)
 * @param len The length of the message data
 * @param userData User-provided context pointer
 */
typedef void (*ArchivistCallback)(int callerRet, const char *msg, size_t len, void *userData);

/*******************************************************************************
 * Context Lifecycle
 ******************************************************************************/

/**
 * Create a new instance of an Archivist node.
 *
 * @param configToml TOML string with configuration overwriting defaults (can be NULL or empty string)
 * @param callback Callback function for the result
 * @param userData User-provided context pointer
 * @return Opaque pointer to the ArchivistContext, or NULL on failure
 *
 * Typical usage:
 *   ctx = archivist_new(configToml, myCallback, myUserData);
 *   archivist_create(ctx, ...);
 *   archivist_start(ctx, ...);
 *   ...
 *   archivist_stop(ctx, ...);
 *   archivist_destroy(ctx, ...);
 */
void *archivist_new(
    const char *configToml,
    ArchivistCallback callback,
    void *userData);

/**
 * Start the Archivist node.
 * The node can be started and stopped multiple times.
 * 
 * @param ctx Context pointer from archivist_new
 * @param callback Callback function for the result
 * @param userData User-provided context pointer
 * @return RET_OK if dispatched, RET_ERR on failure
 */
int archivist_create(void *ctx, ArchivistCallback callback, void *userData);

/**
 * Start the Archivist node.
 * The node can be started and stopped multiple times.
 * 
 * @param ctx Context pointer from archivist_new
 * @param callback Callback function for the result
 * @param userData User-provided context pointer
 * @return RET_OK if dispatched, RET_ERR on failure
 */
int archivist_start(void *ctx, ArchivistCallback callback, void *userData);

/**
 * Stop the Archivist node.
 * The node can be started and stopped multiple times.
 * 
 * @param ctx Context pointer from archivist_new
 * @param callback Callback function for the result
 * @param userData User-provided context pointer
 * @return RET_OK if dispatched, RET_ERR on failure
 */
int archivist_stop(void *ctx, ArchivistCallback callback, void *userData);

/**
 * Close the Archivist node.
 * Use this to release resources before destroying the node.
 * 
 * @param ctx Context pointer from archivist_new
 * @param callback Callback function for the result
 * @param userData User-provided context pointer
 * @return RET_OK if dispatched, RET_ERR on failure
 */
int archivist_close(void *ctx, ArchivistCallback callback, void *userData);

/**
 * Destroy an instance of an Archivist node.
 * This will free all resources associated with the node.
 * The node must be stopped and closed before calling this function.
 * 
 * @param ctx Context pointer from archivist_new
 * @param callback Callback function for the result
 * @param userData User-provided context pointer
 * @return RET_OK if dispatched, RET_ERR on failure
 */
int archivist_destroy(void *ctx, ArchivistCallback callback, void *userData);

/*******************************************************************************
 * Version Information
 ******************************************************************************/

/**
 * Get the Archivist version string.
 * This call does not require the node to be started.
 * 
 * @param ctx Context pointer from archivist_new
 * @param callback Callback function for the result
 * @param userData User-provided context pointer
 * @return RET_OK if dispatched, RET_ERR on failure
 */
int archivist_version(void *ctx, ArchivistCallback callback, void *userData);

/**
 * Get the Archivist contracts revision.
 * This call does not require the node to be started.
 * 
 * @param ctx Context pointer from archivist_new
 * @param callback Callback function for the result
 * @param userData User-provided context pointer
 * @return RET_OK if dispatched, RET_ERR on failure
 */
int archivist_revision(void *ctx, ArchivistCallback callback, void *userData);

/**
 * Get the repo (data-dir) used by the node.
 * 
 * @param ctx Context pointer from archivist_new
 * @param callback Callback function for the result
 * @param userData User-provided context pointer
 * @return RET_OK if dispatched, RET_ERR on failure
 */
int archivist_repo(void *ctx, ArchivistCallback callback, void *userData);

/*******************************************************************************
 * Debug Operations
 ******************************************************************************/

/**
 * Retrieve debug information (JSON).
 * 
 * Example return structure:
 * {
 *   "id": "...",
 *   "addrs": ["..."],
 *   "spr": "",
 *   "announceAddresses": ["..."],
 *   "table": {
 *     "localNode": "",
 *     "nodes": [...]
 *   }
 * }
 * 
 * @param ctx Context pointer from archivist_new
 * @param callback Callback function for the result
 * @param userData User-provided context pointer
 * @return RET_OK if dispatched, RET_ERR on failure
 */
int archivist_debug(void *ctx, ArchivistCallback callback, void *userData);

/**
 * Get the node's Signed Peer Record (SPR).
 * 
 * @param ctx Context pointer from archivist_new
 * @param callback Callback function for the result
 * @param userData User-provided context pointer
 * @return RET_OK if dispatched, RET_ERR on failure
 */
int archivist_spr(void *ctx, ArchivistCallback callback, void *userData);

/**
 * Get the node's peer ID.
 * 
 * @param ctx Context pointer from archivist_new
 * @param callback Callback function for the result
 * @param userData User-provided context pointer
 * @return RET_OK if dispatched, RET_ERR on failure
 */
int archivist_peer_id(void *ctx, ArchivistCallback callback, void *userData);

/**
 * Set the log level at run time.
 * 
 * @param ctx Context pointer from archivist_new
 * @param logLevel Log level: "TRACE", "DEBUG", "INFO", "NOTICE", "WARN", "ERROR", or "FATAL"
 * @param callback Callback function for the result
 * @param userData User-provided context pointer
 * @return RET_OK if dispatched, RET_ERR on failure
 */
int archivist_log_level(
    void *ctx,
    const char *logLevel,
    ArchivistCallback callback,
    void *userData);

/*******************************************************************************
 * P2P Networking
 ******************************************************************************/

/**
 * Connect to a peer by using peerAddresses if provided, otherwise use peerId.
 * Note that the peerId has to be advertised in the DHT for this to work.
 * 
 * @param ctx Context pointer from archivist_new
 * @param peerId The peer ID to connect to
 * @param peerAddresses Array of multiaddresses to dial (can be NULL)
 * @param peerAddressesSize Number of addresses in the array
 * @param callback Callback function for the result
 * @param userData User-provided context pointer
 * @return RET_OK if dispatched, RET_ERR on failure
 */
int archivist_connect(
    void *ctx,
    const char *peerId,
    const char **peerAddresses,
    size_t peerAddressesSize,
    ArchivistCallback callback,
    void *userData);

/**
 * Get the number of connected peers.
 * 
 * @param ctx Context pointer from archivist_new
 * @param callback Callback function for the result (returns count as string)
 * @param userData User-provided context pointer
 * @return RET_OK if dispatched, RET_ERR on failure
 */
int archivist_connected_peers(void *ctx, ArchivistCallback callback, void *userData);

/**
 * Get list of connected peer IDs as JSON array.
 * 
 * @param ctx Context pointer from archivist_new
 * @param callback Callback function for the result
 * @param userData User-provided context pointer
 * @return RET_OK if dispatched, RET_ERR on failure
 */
int archivist_connected_peer_ids(void *ctx, ArchivistCallback callback, void *userData);

/**
 * Find a peer by ID using DHT discovery.
 * 
 * @param ctx Context pointer from archivist_new
 * @param peerId The peer ID to find
 * @param callback Callback function for the result (returns peer record as JSON)
 * @param userData User-provided context pointer
 * @return RET_OK if dispatched, RET_ERR on failure
 */
int archivist_find_peer(
    void *ctx,
    const char *peerId,
    ArchivistCallback callback,
    void *userData);

/**
 * Disconnect from a specific peer.
 * 
 * @param ctx Context pointer from archivist_new
 * @param peerId The peer ID to disconnect from
 * @param callback Callback function for the result
 * @param userData User-provided context pointer
 * @return RET_OK if dispatched, RET_ERR on failure
 */
int archivist_disconnect(
    void *ctx,
    const char *peerId,
    ArchivistCallback callback,
    void *userData);

/*******************************************************************************
 * Upload Operations
 ******************************************************************************/

/**
 * Initialize an upload session for a file.
 * 
 * @param ctx Context pointer from archivist_new
 * @param filepath Absolute path for file upload; for chunk uploads it's the file name
 * @param chunkSize Chunk size for upload (default: 65536 bytes)
 * @param callback Callback function for the result (returns sessionId)
 * @param userData User-provided context pointer
 * @return RET_OK if dispatched, RET_ERR on failure
 */
int archivist_upload_init(
    void *ctx,
    const char *filepath,
    size_t chunkSize,
    ArchivistCallback callback,
    void *userData);

/**
 * Upload a chunk for the given sessionId.
 * 
 * @param ctx Context pointer from archivist_new
 * @param sessionId The upload session ID
 * @param chunk Pointer to the chunk data
 * @param len Length of the chunk data
 * @param callback Callback function for the result
 * @param userData User-provided context pointer
 * @return RET_OK if dispatched, RET_ERR on failure
 */
int archivist_upload_chunk(
    void *ctx,
    const char *sessionId,
    const uint8_t *chunk,
    size_t len,
    ArchivistCallback callback,
    void *userData);

/**
 * Finalize an upload session identified by sessionId.
 * 
 * @param ctx Context pointer from archivist_new
 * @param sessionId The upload session ID
 * @param callback Callback function for the result (returns CID)
 * @param userData User-provided context pointer
 * @return RET_OK if dispatched, RET_ERR on failure
 */
int archivist_upload_finalize(
    void *ctx,
    const char *sessionId,
    ArchivistCallback callback,
    void *userData);

/**
 * Cancel an ongoing upload session.
 * 
 * @param ctx Context pointer from archivist_new
 * @param sessionId The upload session ID
 * @param callback Callback function for the result
 * @param userData User-provided context pointer
 * @return RET_OK if dispatched, RET_ERR on failure
 */
int archivist_upload_cancel(
    void *ctx,
    const char *sessionId,
    ArchivistCallback callback,
    void *userData);

/**
 * Upload the file defined as filepath in the init method.
 * 
 * @param ctx Context pointer from archivist_new
 * @param sessionId The upload session ID
 * @param callback Callback function for the result (returns CID, may send RET_PROGRESS)
 * @param userData User-provided context pointer
 * @return RET_OK if dispatched, RET_ERR on failure
 */
int archivist_upload_file(
    void *ctx,
    const char *sessionId,
    ArchivistCallback callback,
    void *userData);

/*******************************************************************************
 * Download Operations
 ******************************************************************************/

/**
 * Initialize a download for cid.
 * 
 * @param ctx Context pointer from archivist_new
 * @param cid The content identifier to download
 * @param chunkSize Chunk size for download (default: 65536 bytes)
 * @param local Whether to attempt local store retrieval only
 * @param callback Callback function for the result
 * @param userData User-provided context pointer
 * @return RET_OK if dispatched, RET_ERR on failure
 */
int archivist_download_init(
    void *ctx,
    const char *cid,
    size_t chunkSize,
    bool local,
    ArchivistCallback callback,
    void *userData);

/**
 * Perform a streaming download for cid.
 * 
 * @param ctx Context pointer from archivist_new
 * @param cid The content identifier to download
 * @param chunkSize Chunk size for download (default: 65536 bytes)
 * @param local Whether to attempt local store retrieval only
 * @param filepath If provided, content is written to this file
 * @param callback Callback function for the result (may send RET_PROGRESS)
 * @param userData User-provided context pointer
 * @return RET_OK if dispatched, RET_ERR on failure
 */
int archivist_download_stream(
    void *ctx,
    const char *cid,
    size_t chunkSize,
    bool local,
    const char *filepath,
    ArchivistCallback callback,
    void *userData);

/**
 * Download a chunk for the given cid.
 * The chunk will be returned via the callback using RET_PROGRESS.
 * 
 * @param ctx Context pointer from archivist_new
 * @param cid The content identifier to download
 * @param callback Callback function for the result
 * @param userData User-provided context pointer
 * @return RET_OK if dispatched, RET_ERR on failure
 */
int archivist_download_chunk(
    void *ctx,
    const char *cid,
    ArchivistCallback callback,
    void *userData);

/**
 * Cancel an ongoing download for cid.
 * 
 * @param ctx Context pointer from archivist_new
 * @param cid The content identifier to cancel
 * @param callback Callback function for the result
 * @param userData User-provided context pointer
 * @return RET_OK if dispatched, RET_ERR on failure
 */
int archivist_download_cancel(
    void *ctx,
    const char *cid,
    ArchivistCallback callback,
    void *userData);

/**
 * Retrieve the manifest for the given cid (JSON).
 * 
 * Example return structure:
 * {
 *   "treeCid": "...",
 *   "datasetSize": 123456,
 *   "blockSize": 65536,
 *   "filename": "example.txt",
 *   "mimetype": "text/plain",
 *   "protected": false
 * }
 * 
 * @param ctx Context pointer from archivist_new
 * @param cid The content identifier
 * @param callback Callback function for the result
 * @param userData User-provided context pointer
 * @return RET_OK if dispatched, RET_ERR on failure
 */
int archivist_download_manifest(
    void *ctx,
    const char *cid,
    ArchivistCallback callback,
    void *userData);

/*******************************************************************************
 * Storage Operations
 ******************************************************************************/

/**
 * Retrieve the list of manifests stored in the node.
 * 
 * @param ctx Context pointer from archivist_new
 * @param callback Callback function for the result (JSON array)
 * @param userData User-provided context pointer
 * @return RET_OK if dispatched, RET_ERR on failure
 */
int archivist_list(void *ctx, ArchivistCallback callback, void *userData);

/**
 * Retrieve storage space information (JSON).
 * 
 * Example return structure:
 * {
 *   "totalBlocks": 100000,
 *   "quotaMaxBytes": 0,
 *   "quotaUsedBytes": 0,
 *   "quotaReservedBytes": 0
 * }
 * 
 * @param ctx Context pointer from archivist_new
 * @param callback Callback function for the result
 * @param userData User-provided context pointer
 * @return RET_OK if dispatched, RET_ERR on failure
 */
int archivist_space(void *ctx, ArchivistCallback callback, void *userData);

/**
 * Delete the content identified by cid.
 * 
 * @param ctx Context pointer from archivist_new
 * @param cid The content identifier to delete
 * @param callback Callback function for the result
 * @param userData User-provided context pointer
 * @return RET_OK if dispatched, RET_ERR on failure
 */
int archivist_delete(
    void *ctx,
    const char *cid,
    ArchivistCallback callback,
    void *userData);

/**
 * Fetch content identified by cid from the network into local store.
 * The download is done in background so the callback will not receive progress updates.
 * 
 * @param ctx Context pointer from archivist_new
 * @param cid The content identifier to fetch
 * @param callback Callback function for the result
 * @param userData User-provided context pointer
 * @return RET_OK if dispatched, RET_ERR on failure
 */
int archivist_fetch(
    void *ctx,
    const char *cid,
    ArchivistCallback callback,
    void *userData);

/**
 * Check if content identified by cid exists in local store.
 * 
 * @param ctx Context pointer from archivist_new
 * @param cid The content identifier to check
 * @param callback Callback function for the result (returns "true" or "false")
 * @param userData User-provided context pointer
 * @return RET_OK if dispatched, RET_ERR on failure
 */
int archivist_exists(
    void *ctx,
    const char *cid,
    ArchivistCallback callback,
    void *userData);

/**
 * Get total size of locally stored data.
 * 
 * @param ctx Context pointer from archivist_new
 * @param callback Callback function for the result (returns size in bytes as string)
 * @param userData User-provided context pointer
 * @return RET_OK if dispatched, RET_ERR on failure
 */
int archivist_local_size(void *ctx, ArchivistCallback callback, void *userData);

/**
 * Get count of blocks in local storage.
 * 
 * @param ctx Context pointer from archivist_new
 * @param callback Callback function for the result (returns count as string)
 * @param userData User-provided context pointer
 * @return RET_OK if dispatched, RET_ERR on failure
 */
int archivist_block_count(void *ctx, ArchivistCallback callback, void *userData);

/*******************************************************************************
 * Event Callback
 ******************************************************************************/

/**
 * Set an event callback for global events.
 * Reserved for future use.
 * 
 * @param ctx Context pointer from archivist_new
 * @param callback Callback function for events
 * @param userData User-provided context pointer
 */
void archivist_set_event_callback(
    void *ctx,
    ArchivistCallback callback,
    void *userData);

#ifdef __cplusplus
}
#endif

#endif /* __libarchivist__ */
