/**
 * Spark KV - Local Storage State Management
 * A lightweight key-value store with TypeScript support for persistent state
 */

type StorageValue = string | number | boolean | object | null;

interface SparkKVOptions {
  prefix?: string;
  serialize?: (value: StorageValue) => string;
  deserialize?: (value: string) => StorageValue;
}

const defaultOptions: SparkKVOptions = {
  prefix: 'aitherzero',
  serialize: JSON.stringify,
  deserialize: JSON.parse,
};

class SparkKV {
  private prefix: string;
  private serialize: (value: StorageValue) => string;
  private deserialize: (value: string) => StorageValue;

  constructor(options: SparkKVOptions = {}) {
    const opts = { ...defaultOptions, ...options };
    this.prefix = opts.prefix!;
    this.serialize = opts.serialize!;
    this.deserialize = opts.deserialize!;
  }

  private getKey(key: string): string {
    return `${this.prefix}:${key}`;
  }

  private isClient(): boolean {
    return typeof window !== 'undefined';
  }

  get<T = StorageValue>(key: string, defaultValue?: T): T | null {
    if (!this.isClient()) return defaultValue ?? null;
    
    try {
      const item = localStorage.getItem(this.getKey(key));
      if (item === null) return defaultValue ?? null;
      return this.deserialize(item) as T;
    } catch (error) {
      console.error(`SparkKV: Error reading key "${key}"`, error);
      return defaultValue ?? null;
    }
  }

  set<T extends StorageValue>(key: string, value: T): boolean {
    if (!this.isClient()) return false;
    
    try {
      localStorage.setItem(this.getKey(key), this.serialize(value));
      return true;
    } catch (error) {
      console.error(`SparkKV: Error writing key "${key}"`, error);
      return false;
    }
  }

  remove(key: string): boolean {
    if (!this.isClient()) return false;
    
    try {
      localStorage.removeItem(this.getKey(key));
      return true;
    } catch (error) {
      console.error(`SparkKV: Error removing key "${key}"`, error);
      return false;
    }
  }

  has(key: string): boolean {
    if (!this.isClient()) return false;
    return localStorage.getItem(this.getKey(key)) !== null;
  }

  clear(): boolean {
    if (!this.isClient()) return false;
    
    try {
      const keysToRemove: string[] = [];
      for (let i = 0; i < localStorage.length; i++) {
        const key = localStorage.key(i);
        if (key?.startsWith(`${this.prefix}:`)) {
          keysToRemove.push(key);
        }
      }
      keysToRemove.forEach(key => localStorage.removeItem(key));
      return true;
    } catch (error) {
      console.error('SparkKV: Error clearing storage', error);
      return false;
    }
  }

  keys(): string[] {
    if (!this.isClient()) return [];
    
    const keys: string[] = [];
    const prefixLength = this.prefix.length + 1;
    
    for (let i = 0; i < localStorage.length; i++) {
      const key = localStorage.key(i);
      if (key?.startsWith(`${this.prefix}:`)) {
        keys.push(key.substring(prefixLength));
      }
    }
    
    return keys;
  }

  // Batch operations
  setMany(items: Record<string, StorageValue>): boolean {
    return Object.entries(items).every(([key, value]) => this.set(key, value));
  }

  getMany<T = StorageValue>(keys: string[]): Record<string, T | null> {
    return keys.reduce((acc, key) => {
      acc[key] = this.get<T>(key);
      return acc;
    }, {} as Record<string, T | null>);
  }
}

// Default instance
export const sparkKV = new SparkKV();

// Factory function for custom instances
export function createSparkKV(options?: SparkKVOptions): SparkKV {
  return new SparkKV(options);
}

// React hook for reactive state
import { useState, useEffect, useCallback, useRef } from 'react';

export function useSparkKV<T = StorageValue>(
  key: string,
  defaultValue: T
): [T, (value: T | ((prev: T) => T)) => void, () => void] {
  // Use ref to avoid infinite loops with object/array default values
  const defaultValueRef = useRef(defaultValue);
  
  const [value, setValue] = useState<T>(() => {
    // Initialize from storage on first render (client-side only)
    if (typeof window !== 'undefined') {
      const stored = sparkKV.get<T>(key, defaultValue);
      return stored ?? defaultValue;
    }
    return defaultValue;
  });

  // Only sync on mount and key changes, not on defaultValue changes
  useEffect(() => {
    const stored = sparkKV.get<T>(key, defaultValueRef.current);
    if (stored !== null) {
      setValue(stored);
    }
  }, [key]);

  const set = useCallback((newValue: T | ((prev: T) => T)) => {
    setValue((current) => {
      const resolvedValue = newValue instanceof Function ? (newValue as (prev: T) => T)(current) : newValue;
      sparkKV.set(key, resolvedValue as StorageValue);
      return resolvedValue;
    });
  }, [key]);

  const remove = useCallback(() => {
    setValue(defaultValueRef.current);
    sparkKV.remove(key);
  }, [key]);

  return [value, set, remove];
}

export default sparkKV;
