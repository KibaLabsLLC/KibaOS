/*
 * KibaOS Global Undo Engine & Command Palette Registry
 */

#ifndef _SHELL_PALETTE_UNDO_H_
#define _SHELL_PALETTE_UNDO_H_

#include <windows.h>
#include <vector>
#include <string>
#include <functional>

struct PaletteAction {
    std::wstring Id;
    std::wstring Title;
    std::wstring Category;
    std::wstring Shortcut;
    std::function<void()> Execute;
};

class CommandPaletteRegistry {
public:
    static CommandPaletteRegistry& Instance() {
        static CommandPaletteRegistry reg;
        return reg;
    }

    void Register(const PaletteAction& action) {
        m_Actions.push_back(action);
    }

    const std::vector<PaletteAction>& Actions() const {
        return m_Actions;
    }

private:
    std::vector<PaletteAction> m_Actions;
};

// Global Undo Stack Engine
struct UndoOperation {
    std::wstring Description;
    std::function<void()> UndoFunc;
    std::function<void()> RedoFunc;
};

class UndoEngine {
public:
    static UndoEngine& Instance() {
        static UndoEngine engine;
        return engine;
    }

    void Push(const UndoOperation& op) {
        m_UndoStack.push_back(op);
        m_RedoStack.clear();
    }

    bool Undo() {
        if (m_UndoStack.empty()) return false;
        UndoOperation op = m_UndoStack.back();
        m_UndoStack.pop_back();
        if (op.UndoFunc) op.UndoFunc();
        m_RedoStack.push_back(op);
        return true;
    }

    bool Redo() {
        if (m_RedoStack.empty()) return false;
        UndoOperation op = m_RedoStack.back();
        m_RedoStack.pop_back();
        if (op.RedoFunc) op.RedoFunc();
        m_UndoStack.push_back(op);
        return true;
    }

private:
    std::vector<UndoOperation> m_UndoStack;
    std::vector<UndoOperation> m_RedoStack;
};

#endif /* _SHELL_PALETTE_UNDO_H_ */
