/**
 * Epoch Database - Local JSON database for storing decrypted strategies and APYs
 *
 * This acts as a local cache to avoid re-decrypting strategies from chain.
 * Data is incrementally written as StrategySubmitted events are processed.
 */

import * as fs from 'fs';
import * as path from 'path';

// Database file path
const DB_PATH = path.resolve(__dirname, './data/epochDatabase.json');

// Ensure data directory exists
const DATA_DIR = path.dirname(DB_PATH);
if (!fs.existsSync(DATA_DIR)) {
    fs.mkdirSync(DATA_DIR, { recursive: true });
}

/**
 * Strategy node with all data needed to reconstruct calldata
 */
export interface StrategyNode {
    encoder: string;        // Encoder/sanitizer address
    target: string;         // Protocol target address
    selector: string;       // Function selector (e.g., "0x617ba037")
    args: any[];           // Decrypted argument values
    argTypes: number[];    // FHE utypes for each arg (for encoding)
}

/**
 * Strategy submission data
 */
export interface StrategyData {
    submitter: string;
    nodes: StrategyNode[];
    simulatedAPY: number;      // APY in basis points
    submittedAt: number;       // Timestamp
    targetChainId: number;     // Destination chain
}

/**
 * Epoch data structure
 */
export interface EpochData {
    epochNumber: number;
    weights: number[];         // Capital allocation weights
    notionalPerTrader: string; // Simulation capital (as string to preserve precision)
    allocatedCapital: string;  // Real capital to deploy
    strategies: { [submitter: string]: StrategyData };
}

/**
 * Database structure
 */
interface Database {
    epochs: { [epochNumber: string]: EpochData };
}

/**
 * Load database from disk
 */
function loadDatabase(): Database {
    try {
        if (fs.existsSync(DB_PATH)) {
            const data = fs.readFileSync(DB_PATH, 'utf8');
            return JSON.parse(data);
        }
    } catch (error) {
        console.error('⚠️ Error loading database, creating new one:', error);
    }

    return { epochs: {} };
}

/**
 * Custom JSON serializer that handles BigInt
 */
function bigIntReplacer(key: string, value: any): any {
    if (typeof value === 'bigint') {
        return value.toString();
    }
    return value;
}

/**
 * Save database to disk
 */
function saveDatabase(db: Database): void {
    try {
        fs.writeFileSync(DB_PATH, JSON.stringify(db, bigIntReplacer, 2), 'utf8');
    } catch (error) {
        console.error('❌ Error saving database:', error);
        throw error;
    }
}

/**
 * Initialize epoch if it doesn't exist
 */
export function initializeEpoch(
    epochNumber: number,
    weights: number[],
    notionalPerTrader: string,
    allocatedCapital: string
): void {
    const db = loadDatabase();
    const epochKey = epochNumber.toString();

    if (!db.epochs[epochKey]) {
        db.epochs[epochKey] = {
            epochNumber,
            weights,
            notionalPerTrader,
            allocatedCapital,
            strategies: {}
        };
        saveDatabase(db);
        console.log(`✅ Initialized epoch ${epochNumber} in database`);
    }
}

/**
 * Save a strategy for a specific epoch
 */
export function saveStrategy(
    epochNumber: number,
    submitter: string,
    nodes: StrategyNode[],
    simulatedAPY: number,
    submittedAt: number,
    targetChainId: number
): void {
    const db = loadDatabase();
    const epochKey = epochNumber.toString();

    // Ensure epoch exists
    if (!db.epochs[epochKey]) {
        console.warn(`⚠️ Epoch ${epochNumber} not initialized, creating it...`);
        db.epochs[epochKey] = {
            epochNumber,
            weights: [],
            notionalPerTrader: '0',
            allocatedCapital: '0',
            strategies: {}
        };
    }

    // Save strategy
    db.epochs[epochKey].strategies[submitter] = {
        submitter,
        nodes,
        simulatedAPY,
        submittedAt,
        targetChainId
    };

    saveDatabase(db);
    console.log(`✅ Saved strategy for ${submitter} in epoch ${epochNumber}`);
}

/**
 * Get all strategies for an epoch
 */
export function getEpochStrategies(epochNumber: number): { [submitter: string]: StrategyData } {
    const db = loadDatabase();
    const epochKey = epochNumber.toString();

    if (!db.epochs[epochKey]) {
        return {};
    }

    return db.epochs[epochKey].strategies;
}

/**
 * Get a specific strategy
 */
export function getStrategy(epochNumber: number, submitter: string): StrategyData | null {
    const db = loadDatabase();
    const epochKey = epochNumber.toString();

    if (!db.epochs[epochKey] || !db.epochs[epochKey].strategies[submitter]) {
        return null;
    }

    return db.epochs[epochKey].strategies[submitter];
}

/**
 * Get epoch data
 */
export function getEpochData(epochNumber: number): EpochData | null {
    const db = loadDatabase();
    const epochKey = epochNumber.toString();

    return db.epochs[epochKey] || null;
}

/**
 * Get all submitters for an epoch (sorted by APY, highest first)
 */
export function getEpochSubmitters(epochNumber: number, sortByAPY: boolean = true): string[] {
    const db = loadDatabase();
    const epochKey = epochNumber.toString();

    if (!db.epochs[epochKey]) {
        return [];
    }

    const submitters = Object.keys(db.epochs[epochKey].strategies);

    if (sortByAPY) {
        return submitters.sort((a, b) => {
            const apyA = db.epochs[epochKey].strategies[a].simulatedAPY;
            const apyB = db.epochs[epochKey].strategies[b].simulatedAPY;
            return apyB - apyA; // Descending order (highest APY first)
        });
    }

    return submitters;
}

/**
 * Check if a strategy exists for a submitter in an epoch
 */
export function hasStrategy(epochNumber: number, submitter: string): boolean {
    const db = loadDatabase();
    const epochKey = epochNumber.toString();

    return !!(db.epochs[epochKey]?.strategies[submitter]);
}

/**
 * Get database path (for debugging)
 */
export function getDatabasePath(): string {
    return DB_PATH;
}

/**
 * Clear all data (use with caution!)
 */
export function clearDatabase(): void {
    const db: Database = { epochs: {} };
    saveDatabase(db);
    console.log('🗑️ Database cleared');
}
