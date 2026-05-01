import * as React from "react";
interface CheckboxProps extends React.InputHTMLAttributes<HTMLInputElement> {
}
export function Checkbox(props: CheckboxProps) {
    return <input type="checkbox" className="h-4 w-4 rounded border-border accent-primary" {...props}/>;
}
